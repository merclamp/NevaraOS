//! nved — Nevara Visual EDitor
//!
//! A terminal text editor written in Zig for Nevara OS.
//! Uses VT100 escape sequences directly; no curses required.
//! Storage: gap buffer (fast insert/delete at cursor).
//! Interface: raw TTY via SYS_tty_mode=1020.
//!
//! Keys:
//!   Arrow keys / PgUp / PgDn / Home / End — movement
//!   Printable chars — insert
//!   Backspace / Del — delete
//!   Ctrl+S — save
//!   Ctrl+Q — quit (asks if unsaved)
//!   Ctrl+G — go to line number

const nstd = @import("nstd");
const std = @import("std");

// ---- Entry point (same pattern as nsh/zinit) --------------------------------
export fn _start() callconv(.naked) noreturn {
    asm volatile (
        \\ movq (%rsp), %rdi
        \\ leaq 8(%rsp), %rsi
        \\ call startMain
    );
}
export fn startMain(c: usize, v: [*]const ?[*:0]const u8) callconv(.c) noreturn {
    nstd.start(c, v);
}

// ---- Screen dimensions (fixed for 800×600 at 8px font) ---------------------
const SCREEN_COLS: usize = 100;
const SCREEN_ROWS: usize = 75;
const EDIT_ROWS: usize = SCREEN_ROWS - 2; // reserve top status + bottom status

// ---- Gap buffer -------------------------------------------------------------
// Layout: [text_before_gap ... GAP ... text_after_gap]
// cursor is always at the start of the gap.

const INIT_SIZE: usize = 4096;
const GAP_MIN:   usize = 64;

const Buf = struct {
    data:     []u8,
    gap_lo:   usize, // start of gap (= cursor position in logical text)
    gap_hi:   usize, // end of gap (exclusive)

    fn init(alloc: std.mem.Allocator) !Buf {
        const data = try alloc.alloc(u8, INIT_SIZE);
        return .{ .data = data, .gap_lo = 0, .gap_hi = INIT_SIZE };
    }

    fn len(self: *const Buf) usize {
        return self.data.len - (self.gap_hi - self.gap_lo);
    }

    fn gapSize(self: *const Buf) usize {
        return self.gap_hi - self.gap_lo;
    }

    // Logical index → physical index.
    fn phys(self: *const Buf, idx: usize) usize {
        if (idx < self.gap_lo) return idx;
        return idx + self.gapSize();
    }

    // Get byte at logical index.
    fn get(self: *const Buf, idx: usize) u8 {
        return self.data[self.phys(idx)];
    }

    // Move gap to logical position pos.
    fn moveTo(self: *Buf, pos: usize) void {
        if (pos == self.gap_lo) return;
        const gap = self.gapSize();
        if (pos < self.gap_lo) {
            // Move gap left: copy chars from before gap to after gap (right end).
            const n = self.gap_lo - pos;
            std.mem.copyBackwards(u8, self.data[self.gap_hi - n .. self.gap_hi], self.data[pos .. self.gap_lo]);
            self.gap_lo = pos;
            self.gap_hi = pos + gap;
        } else {
            // Move gap right.
            const n = pos - self.gap_lo;
            @memcpy(self.data[self.gap_lo .. self.gap_lo + n], self.data[self.gap_hi .. self.gap_hi + n]);
            self.gap_lo = pos;
            self.gap_hi = pos + gap;
        }
    }

    // Ensure gap is at least GAP_MIN, growing the buffer if needed.
    fn ensureGap(self: *Buf, alloc: std.mem.Allocator) !void {
        if (self.gapSize() >= GAP_MIN) return;
        const new_size = self.data.len * 2;
        const new_data = try alloc.alloc(u8, new_size);
        // Copy pre-gap.
        @memcpy(new_data[0..self.gap_lo], self.data[0..self.gap_lo]);
        // Copy post-gap with enlarged gap.
        const old_post_len = self.data.len - self.gap_hi;
        const new_gap_hi = new_size - old_post_len;
        @memcpy(new_data[new_gap_hi..], self.data[self.gap_hi..]);
        alloc.free(self.data);
        self.data = new_data;
        self.gap_hi = new_gap_hi;
    }

    // Insert byte at cursor (gap_lo), advance cursor.
    fn insert(self: *Buf, alloc: std.mem.Allocator, c: u8) !void {
        try self.ensureGap(alloc);
        self.data[self.gap_lo] = c;
        self.gap_lo += 1;
    }

    // Delete byte before cursor (backspace).
    fn deleteBefore(self: *Buf) void {
        if (self.gap_lo == 0) return;
        self.gap_lo -= 1;
    }

    // Delete byte at cursor (del key).
    fn deleteAt(self: *Buf) void {
        if (self.gap_hi >= self.data.len) return;
        self.gap_hi += 1;
    }

    // Cursor position in logical text.
    fn cursor(self: *const Buf) usize {
        return self.gap_lo;
    }

    // Move cursor left by 1.
    fn cursorLeft(self: *Buf) void {
        if (self.gap_lo == 0) return;
        self.gap_lo -= 1;
        self.gap_hi -= 1;
        self.data[self.gap_hi] = self.data[self.gap_lo];
    }

    // Move cursor right by 1.
    fn cursorRight(self: *Buf) void {
        if (self.gap_hi >= self.data.len) return;
        self.data[self.gap_lo] = self.data[self.gap_hi];
        self.gap_lo += 1;
        self.gap_hi += 1;
    }
};
// ---- Editor state ----------------------------------------------------------

const Editor = struct {
    buf:      Buf,
    filename: ?[]const u8,
    dirty:    bool,
    top_line: usize,    // first visible line (0-based)
    cx: usize,          // cursor column (0-based, visual)
    cy: usize,          // cursor row relative to top_line (0-based)
    status:   [128]u8,
    status_len: usize,
    quit_confirm: bool, // true = user pressed Ctrl+Q once on dirty buf
};

// ---- Syscall helpers -------------------------------------------------------

const SYS_write:    usize = 1;
const SYS_read:     usize = 0;
const SYS_open:     usize = 2;
const SYS_close:    usize = 3;
const SYS_lseek:    usize = 8;
const SYS_ftruncate:usize = 77;
const SYS_tty_mode: usize = 1020;
const SYS_exit:     usize = 60;

inline fn syscall1(n: usize, a1: usize) usize {
    return asm volatile ("syscall"
        : [ret] "={rax}" (-> usize),
        : [n]  "{rax}" (n),
          [a1] "{rdi}" (a1),
        : .{ .rcx = true, .r11 = true, .memory = true });
}
inline fn syscall2(n: usize, a1: usize, a2: usize) usize {
    return asm volatile ("syscall"
        : [ret] "={rax}" (-> usize),
        : [n]  "{rax}" (n),
          [a1] "{rdi}" (a1),
          [a2] "{rsi}" (a2),
        : .{ .rcx = true, .r11 = true, .memory = true });
}
inline fn syscall3(n: usize, a1: usize, a2: usize, a3: usize) usize {
    return asm volatile ("syscall"
        : [ret] "={rax}" (-> usize),
        : [n]  "{rax}" (n),
          [a1] "{rdi}" (a1),
          [a2] "{rsi}" (a2),
          [a3] "{rdx}" (a3),
        : .{ .rcx = true, .r11 = true, .memory = true });
}

fn rawWrite(s: []const u8) void {
    _ = syscall3(SYS_write, 1, @intFromPtr(s.ptr), s.len);
}

fn rawRead1() ?u8 {
    var c: u8 = 0;
    const n = @as(isize, @bitCast(syscall3(SYS_read, 0, @intFromPtr(&c), 1)));
    if (n <= 0) return null;
    return c;
}

fn setRaw(on: bool) void {
    _ = syscall1(SYS_tty_mode, if (on) 1 else 0);
}

// ---- Output buffer (avoid many small write() calls) -----------------------

var outbuf: [8192]u8 = undefined;
var outlen: usize = 0;

fn obPut(c: u8) void {
    if (outlen >= outbuf.len) obFlush();
    outbuf[outlen] = c;
    outlen += 1;
}

fn obStr(s: []const u8) void {
    for (s) |c| obPut(c);
}

fn obFmt(comptime fmt: []const u8, args: anytype) void {
    var tmp: [256]u8 = undefined;
    const s = std.fmt.bufPrint(&tmp, fmt, args) catch return;
    obStr(s);
}

fn obFlush() void {
    if (outlen == 0) return;
    _ = syscall3(SYS_write, 1, @intFromPtr(&outbuf), outlen);
    outlen = 0;
}

// ---- VT100 helpers ---------------------------------------------------------

fn clearScreen() void { obStr("\x1b[2J"); }
fn moveCursor(row: usize, col: usize) void { obFmt("\x1b[{d};{d}H", .{ row + 1, col + 1 }); }
fn hideCursor() void {}  // fbterm ignores cursor visibility sequences
fn showCursor() void {}

fn invertVideo() void { obStr("\x1b[7m"); }
fn normalVideo() void { obStr("\x1b[0m"); }
fn eraseToEol() void { obStr("\x1b[K"); }

// ---- Line counting helpers -------------------------------------------------

// Count newlines in logical buffer up to (but not including) pos.
fn linesBefore(buf: *const Buf, pos: usize) usize {
    var n: usize = 0;
    var i: usize = 0;
    while (i < pos) : (i += 1) {
        if (buf.get(i) == '\n') n += 1;
    }
    return n;
}

// Find the logical position of the start of line `line` (0-based).
fn lineStart(buf: *const Buf, line: usize) usize {
    var l: usize = 0;
    var i: usize = 0;
    while (i < buf.len()) : (i += 1) {
        if (l == line) return i;
        if (buf.get(i) == '\n') l += 1;
    }
    return buf.len();
}

// Find logical position of the end of line starting at `start`.
fn lineEnd(buf: *const Buf, start: usize) usize {
    var i = start;
    while (i < buf.len() and buf.get(i) != '\n') : (i += 1) {}
    return i;
}

// Count total lines (including last line even without trailing newline).
fn totalLines(buf: *const Buf) usize {
    var n: usize = 1;
    var i: usize = 0;
    while (i < buf.len()) : (i += 1) {
        if (buf.get(i) == '\n') n += 1;
    }
    return n;
}

// ---- Render ----------------------------------------------------------------

fn render(ed: *Editor) void {
    const cur_pos = ed.buf.cursor();
    const cur_line = linesBefore(&ed.buf, cur_pos);
    const cur_line_start = lineStart(&ed.buf, cur_line);
    const cur_col = cur_pos - cur_line_start;

    // Scroll: ensure cursor line is visible.
    if (cur_line < ed.top_line) ed.top_line = cur_line;
    if (cur_line >= ed.top_line + EDIT_ROWS)
        ed.top_line = cur_line - EDIT_ROWS + 1;

    // Hide cursor while drawing to avoid flicker.
    hideCursor();

    // ---- Top status bar (row 0) ----
    moveCursor(0, 0);
    invertVideo();
    const fname = ed.filename orelse "[No Name]";
    const dirty_mark: []const u8 = if (ed.dirty) "[+]" else "   ";
    obFmt(" nved | {s} {s} ", .{ fname, dirty_mark });
    var top_used: usize = 9 + fname.len + 4;
    while (top_used < SCREEN_COLS) : (top_used += 1) obPut(' ');
    normalVideo();

    // ---- Edit area (rows 1..EDIT_ROWS) ----
    var row: usize = 0;
    while (row < EDIT_ROWS) : (row += 1) {
        moveCursor(row + 1, 0);
        eraseToEol();
        const line = ed.top_line + row;
        const ls = lineStart(&ed.buf, line);
        // Past end of file: show tilde on empty rows after content.
        if (ls >= ed.buf.len() and line > 0 and
            (ed.buf.len() == 0 or ed.buf.get(ed.buf.len() - 1) != '\n'))
        {
            // line > total lines: show ~
            const total = totalLines(&ed.buf);
            if (line >= total) {
                obStr("~");
                continue;
            }
        }
        // Line number (4 cols + space).
        obFmt("{d:>4} ", .{line + 1});
        // Line content, clipped to SCREEN_COLS - 5.
        var col: usize = 0;
        var i = ls;
        while (i < ed.buf.len() and col < SCREEN_COLS - 5) : (i += 1) {
            const c = ed.buf.get(i);
            if (c == '\n') break;
            if (c == '\t') {
                const sp = 4 - (col % 4);
                var s: usize = 0;
                while (s < sp and col < SCREEN_COLS - 5) : (s += 1) {
                    obPut(' '); col += 1;
                }
            } else {
                obPut(if (c >= 0x20 and c < 0x7F) c else '?');
                col += 1;
            }
        }
    }

    // ---- Bottom status bar (last row) ----
    moveCursor(SCREEN_ROWS - 1, 0);
    invertVideo();
    var bot_used: usize = 0;
    if (ed.status_len > 0) {
        const msg = ed.status[0..ed.status_len];
        obStr(msg);
        bot_used = ed.status_len;
    } else {
        obFmt(" Ln:{d} Col:{d}  ^S=Save  ^Q=Quit  ^G=GoTo", .{ cur_line + 1, cur_col + 1 });
        bot_used = 40 + numDigits(cur_line + 1) + numDigits(cur_col + 1);
    }
    while (bot_used < SCREEN_COLS) : (bot_used += 1) obPut(' ');
    normalVideo();

    // ---- Place physical cursor ----
    ed.cx = cur_col;
    ed.cy = cur_line - ed.top_line;
    const screen_col = @min(ed.cx + 5, SCREEN_COLS - 1);
    moveCursor(ed.cy + 1, screen_col);
    showCursor();
    obFlush();
}
fn numDigits(n: usize) usize {
    if (n == 0) return 1;
    var d: usize = 0;
    var v = n;
    while (v > 0) { v /= 10; d += 1; }
    return d;
}

// ---- Status message --------------------------------------------------------

fn setStatus(ed: *Editor, comptime fmt: []const u8, args: anytype) void {
    const s = std.fmt.bufPrint(&ed.status, fmt, args) catch return;
    ed.status_len = s.len;
}

fn clearStatus(ed: *Editor) void { ed.status_len = 0; }

// ---- Input handling --------------------------------------------------------

const Key = enum(u16) {
    normal   = 0,
    up       = 256,
    down     = 257,
    left     = 258,
    right    = 259,
    home     = 260,
    end      = 261,
    pgup     = 262,
    pgdn     = 263,
    del      = 264,
    ctrl_s   = 19,
    ctrl_q   = 17,
    ctrl_g   = 7,
    backspace = 8,   // PS/2 kbd sends ASCII 8 (not 127) for Backspace key

    enter    = 13,
    tab      = 9,
    _,
};

fn readKey() Key {
    while (true) {
        const c = rawRead1() orelse continue;
        // Both 8 (BS) and 127 (DEL-as-backspace) treated as backspace.
        if (c == 127) return .backspace;
        if (c == 0x1b) {
            const c2 = rawRead1() orelse return @enumFromInt(0);
            if (c2 != '[') return @enumFromInt(0);
            const c3 = rawRead1() orelse return @enumFromInt(0);
            switch (c3) {
                'A' => return .up,
                'B' => return .down,
                'C' => return .right,
                'D' => return .left,
                'H' => return .home,
                'F' => return .end,
                '1' => { _ = rawRead1(); return .home; },
                '4' => { _ = rawRead1(); return .end; },
                '5' => { _ = rawRead1(); return .pgup; },
                '6' => { _ = rawRead1(); return .pgdn; },
                '3' => { _ = rawRead1(); return .del; },
                else => return @enumFromInt(@as(u16, c3)),
            }
        }
        return @enumFromInt(@as(u16, c));
    }
}

// ---- Cursor movement -------------------------------------------------------

fn moveCursorUp(ed: *Editor) void {
    const pos = ed.buf.cursor();
    const cur_line = linesBefore(&ed.buf, pos);
    if (cur_line == 0) return;
    const cur_ls = lineStart(&ed.buf, cur_line);
    const col = pos - cur_ls;
    const prev_ls = lineStart(&ed.buf, cur_line - 1);
    const prev_le = lineEnd(&ed.buf, prev_ls);
    const new_pos = prev_ls + @min(col, prev_le - prev_ls);
    ed.buf.moveTo(new_pos);
}

fn moveCursorDown(ed: *Editor) void {
    const pos = ed.buf.cursor();
    const cur_line = linesBefore(&ed.buf, pos);
    const cur_ls = lineStart(&ed.buf, cur_line);
    const col = pos - cur_ls;
    const next_ls = lineEnd(&ed.buf, cur_ls) + 1; // skip '\n'
    if (next_ls > ed.buf.len()) return;
    const next_le = lineEnd(&ed.buf, next_ls);
    const new_pos = next_ls + @min(col, next_le - next_ls);
    ed.buf.moveTo(new_pos);
}

fn moveCursorHome(ed: *Editor) void {
    const pos = ed.buf.cursor();
    const cur_line = linesBefore(&ed.buf, pos);
    ed.buf.moveTo(lineStart(&ed.buf, cur_line));
}

fn moveCursorEnd(ed: *Editor) void {
    const pos = ed.buf.cursor();
    const cur_line = linesBefore(&ed.buf, pos);
    const cur_ls = lineStart(&ed.buf, cur_line);
    ed.buf.moveTo(lineEnd(&ed.buf, cur_ls));
}

fn moveCursorPgUp(ed: *Editor) void {
    var i: usize = 0;
    while (i < EDIT_ROWS) : (i += 1) moveCursorUp(ed);
}

fn moveCursorPgDn(ed: *Editor) void {
    var i: usize = 0;
    while (i < EDIT_ROWS) : (i += 1) moveCursorDown(ed);
}

// ---- File I/O --------------------------------------------------------------

fn loadFile(ed: *Editor, alloc: std.mem.Allocator, path: []const u8) !void {
    const fd = @as(isize, @bitCast(syscall3(SYS_open, @intFromPtr(path.ptr), 0, 0)));
    if (fd < 0) return; // new file — start empty
    defer _ = syscall1(SYS_close, @intCast(fd));
    var chunk: [4096]u8 = undefined;
    while (true) {
        const n = @as(isize, @bitCast(syscall3(SYS_read, @intCast(fd), @intFromPtr(&chunk), chunk.len)));
        if (n <= 0) break;
        for (chunk[0..@intCast(n)]) |c| {
            try ed.buf.insert(alloc, c);
        }
    }
    // Move cursor to start.
    ed.buf.moveTo(0);
    ed.dirty = false;
}

fn saveFile(ed: *Editor, path: []const u8) bool {
    // O_WRONLY|O_CREAT|O_TRUNC = 0o100 | 0o001 | 0o1000 = 577 = 0x241
    const fd = @as(isize, @bitCast(syscall3(SYS_open, @intFromPtr(path.ptr), 0o100 | 0o001 | 0o1000, 0o644)));
    if (fd < 0) return false;
    defer _ = syscall1(SYS_close, @intCast(fd));
    // Write pre-gap then post-gap.
    const buf = &ed.buf;
    if (buf.gap_lo > 0)
        _ = syscall3(SYS_write, @intCast(fd), @intFromPtr(buf.data.ptr), buf.gap_lo);
    const post_len = buf.data.len - buf.gap_hi;
    if (post_len > 0)
        _ = syscall3(SYS_write, @intCast(fd), @intFromPtr(buf.data.ptr + buf.gap_hi), post_len);
    ed.dirty = false;
    return true;
}

// ---- Go-to-line prompt -----------------------------------------------------

fn gotoLine(ed: *Editor) void {
    setStatus(ed, "Go to line: ", .{});
    render(ed);
    var linebuf: [16]u8 = undefined;
    var linelen: usize = 0;
    while (true) {
        const k = readKey();
        switch (k) {
            .enter => break,
            .backspace => { if (linelen > 0) { linelen -= 1; setStatus(ed, "Go to line: {s}", .{linebuf[0..linelen]}); render(ed); } },
            else => {
                const c: u16 = @intFromEnum(k);
                if (c >= '0' and c <= '9' and linelen < linebuf.len - 1) {
                    linebuf[linelen] = @intCast(c);
                    linelen += 1;
                    setStatus(ed, "Go to line: {s}", .{linebuf[0..linelen]});
                    render(ed);
                }
            },
        }
    }
    if (linelen == 0) { clearStatus(ed); return; }
    var target: usize = 0;
    for (linebuf[0..linelen]) |c| target = target * 10 + @as(usize, c - '0');
    if (target == 0) target = 1;
    target -= 1; // 0-based
    const total = totalLines(&ed.buf);
    if (target >= total) target = total - 1;
    ed.buf.moveTo(lineStart(&ed.buf, target));
    clearStatus(ed);
}

// ---- Main loop -------------------------------------------------------------

pub fn main() void {
    const alloc = nstd.allocator();

    var ed = Editor{
        .buf      = Buf.init(alloc) catch { nstd.print("nved: out of memory\n"); return; },
        .filename = null,
        .dirty    = false,
        .top_line = 0,
        .cx = 0, .cy = 0,
        .status   = undefined,
        .status_len = 0,
        .quit_confirm = false,
    };

    if (nstd.arg(1)) |filename| {
        ed.filename = filename;
        loadFile(&ed, alloc, filename) catch {};
    } else {
        setStatus(&ed, "Usage: nved <filename>", .{});
    }

    setRaw(true);
    defer setRaw(false);
    clearScreen();

    while (true) {
        render(&ed);
        clearStatus(&ed);
        ed.quit_confirm = false;

        const k = readKey();
        switch (k) {
            .ctrl_q => {
                if (ed.dirty) {
                    setStatus(&ed, "File has unsaved changes! Press ^Q again to quit.", .{});
                    render(&ed);
                    const k2 = readKey();
                    if (@intFromEnum(k2) != 17) continue; // not Ctrl+Q
                }
                // Restore terminal and exit.
                clearScreen();
                moveCursor(0, 0);
                obFlush();
                break;
            },
            .ctrl_s => {
                if (ed.filename) |path| {
                    if (saveFile(&ed, path)) {
                        setStatus(&ed, "Saved: {s}", .{path});
                    } else {
                        setStatus(&ed, "ERROR: could not save {s}", .{path});
                    }
                } else {
                    setStatus(&ed, "No filename — use :w <name> (not yet impl)", .{});
                }
            },
            .ctrl_g => gotoLine(&ed),
            .up    => moveCursorUp(&ed),
            .down  => moveCursorDown(&ed),
            .left  => ed.buf.cursorLeft(),
            .right => ed.buf.cursorRight(),
            .home  => moveCursorHome(&ed),
            .end   => moveCursorEnd(&ed),
            .pgup  => moveCursorPgUp(&ed),
            .pgdn  => moveCursorPgDn(&ed),
            .del   => { ed.buf.deleteAt(); ed.dirty = true; },
            .backspace => { ed.buf.deleteBefore(); ed.dirty = true; },
            .enter => { ed.buf.insert(alloc, '\n') catch {}; ed.dirty = true; },
            .tab   => {
                var i: usize = 0;
                while (i < 4) : (i += 1) ed.buf.insert(alloc, ' ') catch {};
                ed.dirty = true;
            },
            else => {
                const c: u16 = @intFromEnum(k);
                if (c >= 0x20 and c < 0x7F) {
                    ed.buf.insert(alloc, @intCast(c)) catch {};
                    ed.dirty = true;
                }
            },
        }
    }
}
