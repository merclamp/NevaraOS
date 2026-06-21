//! TTY line discipline (canonical mode).
//!
//! Sits between the raw keyboard byte stream (kbd.zig) and the read() syscall on
//! /dev/console. It implements a readline-style line editor: insert/erase at an
//! in-line cursor, word/line kills, Home/End, arrow-key movement, and command
//! history — echoed to the terminal with VT100 escapes the framebuffer console
//! understands. This is what turns the old "type, backspace, Enter" prompt into
//! something that behaves like a real Linux TTY.

const console = @import("arch/x86_64/console.zig");
const kbd = @import("arch/x86_64/kbd.zig");

const LINE_MAX = 256;
const HIST_MAX = 16;

// The line being edited.
var buf: [LINE_MAX]u8 = undefined;
var len: usize = 0;
var pos: usize = 0;

// Command history (most-recent last).
var hist: [HIST_MAX][LINE_MAX]u8 = undefined;
var hist_len: [HIST_MAX]usize = undefined;
var hist_count: usize = 0;
var hist_nav: usize = 0; // [0..hist_count]; == hist_count means the live line

// ---- echo helpers ----------------------------------------------------------

fn moveLeft(n: usize) void {
    var i: usize = 0;
    while (i < n) : (i += 1) console.writeByte(8);
}

fn eraseToEnd() void {
    console.writeString("\x1b[K");
}

// ---- editing primitives ----------------------------------------------------

fn insert(c: u8) void {
    if (len >= LINE_MAX - 1) return; // leave room for the trailing '\n'
    var i: usize = len;
    while (i > pos) : (i -= 1) buf[i] = buf[i - 1];
    buf[pos] = c;
    len += 1;

    // Reprint from the cursor to the end, then step back so the on-screen
    // cursor lands right after the inserted character.
    console.writeString(buf[pos..len]);
    moveLeft(len - (pos + 1));
    pos += 1;
}

fn backspace() void {
    if (pos == 0) return;
    var i: usize = pos - 1;
    while (i < len - 1) : (i += 1) buf[i] = buf[i + 1];
    len -= 1;
    pos -= 1;

    moveLeft(1);
    console.writeString(buf[pos..len]);
    eraseToEnd();
    moveLeft(len - pos);
}

fn deleteAtCursor() void {
    if (pos >= len) return;
    var i: usize = pos;
    while (i < len - 1) : (i += 1) buf[i] = buf[i + 1];
    len -= 1;

    console.writeString(buf[pos..len]);
    eraseToEnd();
    moveLeft(len - pos);
}

fn cursorLeft() void {
    if (pos > 0) {
        pos -= 1;
        moveLeft(1);
    }
}

fn cursorRight() void {
    if (pos < len) {
        console.writeByte(buf[pos]);
        pos += 1;
    }
}

fn cursorHome() void {
    moveLeft(pos);
    pos = 0;
}

fn cursorEnd() void {
    console.writeString(buf[pos..len]);
    pos = len;
}

fn killLine() void {
    moveLeft(pos);
    eraseToEnd();
    len = 0;
    pos = 0;
}

fn killToEnd() void {
    eraseToEnd();
    len = pos;
}

fn killWord() void {
    if (pos == 0) return;
    var start = pos;
    while (start > 0 and buf[start - 1] == ' ') start -= 1;
    while (start > 0 and buf[start - 1] != ' ') start -= 1;
    const removed = pos - start;

    var i: usize = start;
    while (i + removed < len) : (i += 1) buf[i] = buf[i + removed];
    len -= removed;

    moveLeft(removed);
    pos = start;
    console.writeString(buf[pos..len]);
    eraseToEnd();
    moveLeft(len - pos);
}

/// Replace the whole edited line with `src` (used by history recall).
fn replaceLine(src: []const u8) void {
    moveLeft(pos);
    eraseToEnd();
    const n = @min(src.len, LINE_MAX - 1);
    var i: usize = 0;
    while (i < n) : (i += 1) buf[i] = src[i];
    len = n;
    pos = n;
    console.writeString(buf[0..len]);
}

fn clearAndRedraw() void {
    console.writeString("\x1b[2J\x1b[H");
    console.writeString(buf[0..len]);
    moveLeft(len - pos);
}

// ---- history ---------------------------------------------------------------

fn pushHistory() void {
    if (len == 0) return;
    // Skip if identical to the most recent entry.
    if (hist_count > 0 and hist_len[hist_count - 1] == len and
        eql(hist[hist_count - 1][0..len], buf[0..len])) return;

    if (hist_count == HIST_MAX) {
        var i: usize = 0;
        while (i < HIST_MAX - 1) : (i += 1) {
            hist[i] = hist[i + 1];
            hist_len[i] = hist_len[i + 1];
        }
        hist_count = HIST_MAX - 1;
    }
    var i: usize = 0;
    while (i < len) : (i += 1) hist[hist_count][i] = buf[i];
    hist_len[hist_count] = len;
    hist_count += 1;
}

fn eql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    var i: usize = 0;
    while (i < a.len) : (i += 1) if (a[i] != b[i]) return false;
    return true;
}

fn historyUp() void {
    if (hist_nav == 0) return;
    hist_nav -= 1;
    replaceLine(hist[hist_nav][0..hist_len[hist_nav]]);
}

fn historyDown() void {
    if (hist_nav >= hist_count) return;
    hist_nav += 1;
    if (hist_nav == hist_count) {
        replaceLine("");
    } else {
        replaceLine(hist[hist_nav][0..hist_len[hist_nav]]);
    }
}

// ---- escape-sequence decoding ----------------------------------------------

fn handleEscape() void {
    if (kbd.blockingPop() != '[') return;
    const b = kbd.blockingPop();
    switch (b) {
        'A' => historyUp(),
        'B' => historyDown(),
        'C' => cursorRight(),
        'D' => cursorLeft(),
        'H' => cursorHome(),
        'F' => cursorEnd(),
        '0'...'9' => {
            var num: usize = b - '0';
            var n = kbd.blockingPop();
            while (n >= '0' and n <= '9') : (n = kbd.blockingPop()) {
                num = num * 10 + (n - '0');
            }
            // n is the final byte (expected '~').
            if (num == 3) deleteAtCursor();
        },
        else => {},
    }
}

// ---- public entry ----------------------------------------------------------

/// Canonical line read: edit a line interactively and return it (with the
/// trailing '\n') in `out`. Returns the number of bytes written. A bare Ctrl-C
/// or Ctrl-D (on an empty line) returns 0.
pub fn readLine(out: []u8) usize {
    len = 0;
    pos = 0;
    hist_nav = hist_count;

    asm volatile ("sti");
    defer asm volatile ("cli");

    while (true) {
        const c = kbd.blockingPop();
        switch (c) {
            '\r', '\n' => break,
            0x1B => handleEscape(),
            0x08, 0x7F => backspace(),
            0x01 => cursorHome(), // Ctrl-A
            0x05 => cursorEnd(), // Ctrl-E
            0x02 => cursorLeft(), // Ctrl-B
            0x06 => cursorRight(), // Ctrl-F
            0x0B => killToEnd(), // Ctrl-K
            0x15 => killLine(), // Ctrl-U
            0x17 => killWord(), // Ctrl-W
            0x0C => clearAndRedraw(), // Ctrl-L
            0x03 => { // Ctrl-C: abandon the line
                console.writeString("^C\n");
                return 0;
            },
            0x04 => { // Ctrl-D: EOF on empty line, else delete forward
                if (len == 0) return 0;
                deleteAtCursor();
            },
            0x20...0x7E => insert(c),
            else => {},
        }
    }

    console.writeByte('\n');
    pushHistory();

    const n = @min(len, out.len);
    var i: usize = 0;
    while (i < n) : (i += 1) out[i] = buf[i];
    if (n < out.len) {
        out[n] = '\n';
        return n + 1;
    }
    return n;
}

// ---- raw mode --------------------------------------------------------------

/// When true, consoleRead bypasses the line editor and returns bytes one by one.
pub var raw_mode: bool = false;

/// Read one raw byte (used when raw_mode = true). Enables interrupts briefly.
pub fn readRaw(out: []u8) usize {
    if (out.len == 0) return 0;
    asm volatile ("sti");
    defer asm volatile ("cli");
    out[0] = kbd.blockingPop();
    return 1;
}
