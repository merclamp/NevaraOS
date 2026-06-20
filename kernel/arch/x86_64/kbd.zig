//! PS/2 keyboard driver (i8042, scancode set 1).
//!
//! The IRQ1 handler reads a scancode from port 0x60, tracks the modifier state
//! (Shift, Ctrl, Caps Lock), decodes the 0xE0 extended set (arrows, Home/End,
//! Delete, ...) and pushes a byte stream into a ring buffer the TTY line
//! discipline drains. Printable keys produce ASCII; Ctrl+letter produces the
//! matching control code; special keys produce VT100 escape sequences
//! (e.g. Up -> "\x1b[A"), exactly like a real terminal feeds an application.

const DATA: u16 = 0x60;

inline fn inb(port: u16) u8 {
    return asm volatile ("inb %[p], %[r]"
        : [r] "={al}" (-> u8),
        : [p] "{dx}" (port),
    );
}

// Scancode set 1 (make codes 0x00..0x39) -> unshifted ASCII.
const map_lower = [_]u8{
    0,    27,  '1',  '2',  '3',  '4', '5', '6', // 00-07
    '7',  '8', '9',  '0',  '-',  '=', 8,   '\t', // 08-0F
    'q',  'w', 'e',  'r',  't',  'y', 'u', 'i', // 10-17
    'o',  'p', '[',  ']',  '\n', 0,   'a', 's', // 18-1F (1D=ctrl)
    'd',  'f', 'g',  'h',  'j',  'k', 'l', ';', // 20-27
    '\'', '`', 0,    '\\', 'z',  'x', 'c', 'v', // 28-2F (2A=lshift)
    'b',  'n', 'm',  ',',  '.',  '/', 0,   '*', // 30-37 (36=rshift)
    0,    ' ', // 38=lalt, 39=space
};

const map_upper = [_]u8{
    0,    27,  '!',  '@',  '#',  '$', '%', '^',
    '&',  '*', '(',  ')',  '_',  '+', 8,   '\t',
    'Q',  'W', 'E',  'R',  'T',  'Y', 'U', 'I',
    'O',  'P', '{',  '}',  '\n', 0,   'A', 'S',
    'D',  'F', 'G',  'H',  'J',  'K', 'L', ':',
    '"',  '~', 0,    '|',  'Z',  'X', 'C', 'V',
    'B',  'N', 'M',  '<',  '>',  '?', 0,   '*',
    0,    ' ',
};

const RING_SIZE = 256;
var ring: [RING_SIZE]u8 = undefined;
var head: usize = 0; // write index (IRQ)
var tail: usize = 0; // read index (consumer)

var shift: bool = false;
var ctrl: bool = false;
var caps: bool = false;
var ext: bool = false; // a 0xE0 prefix was just seen

fn push(c: u8) void {
    const next = (head + 1) % RING_SIZE;
    if (next == tail) return; // full: drop
    ring[head] = c;
    head = next;
}

fn pushStr(s: []const u8) void {
    for (s) |c| push(c);
}

inline fn isAlpha(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z');
}

fn flipCase(c: u8) u8 {
    if (c >= 'a' and c <= 'z') return c - 32;
    if (c >= 'A' and c <= 'Z') return c + 32;
    return c;
}

/// Map a printable key to its Ctrl control code, or 0 if it has none.
fn toCtrl(c: u8) u8 {
    if (c >= 'a' and c <= 'z') return c - 'a' + 1;
    if (c >= 'A' and c <= 'Z') return c - 'A' + 1;
    return switch (c) {
        '[' => 27,
        '\\' => 28,
        ']' => 29,
        else => 0,
    };
}

/// Translate an extended (0xE0-prefixed) make code into a terminal sequence.
fn pushExtended(make: u8) void {
    switch (make) {
        0x48 => pushStr("\x1b[A"), // up
        0x50 => pushStr("\x1b[B"), // down
        0x4D => pushStr("\x1b[C"), // right
        0x4B => pushStr("\x1b[D"), // left
        0x47 => pushStr("\x1b[H"), // home
        0x4F => pushStr("\x1b[F"), // end
        0x53 => pushStr("\x1b[3~"), // delete
        0x49 => pushStr("\x1b[5~"), // page up
        0x51 => pushStr("\x1b[6~"), // page down
        else => {},
    }
}

/// Called from the IRQ1 handler.
pub fn onIrq() void {
    const code = inb(DATA);

    if (code == 0xE0) {
        ext = true;
        return;
    }

    const released = (code & 0x80) != 0;
    const make = code & 0x7F;

    // Modifier keys update on both make and break.
    switch (make) {
        0x2A, 0x36 => { // shift (left/right)
            shift = !released;
            ext = false;
            return;
        },
        0x1D => { // ctrl (left, or right when extended)
            ctrl = !released;
            ext = false;
            return;
        },
        0x3A => { // caps lock toggles on make
            if (!released) caps = !caps;
            ext = false;
            return;
        },
        0x38 => { // alt (ignored for now)
            ext = false;
            return;
        },
        else => {},
    }

    if (released) {
        ext = false;
        return;
    }

    if (ext) {
        ext = false;
        pushExtended(make);
        return;
    }

    if (make >= map_lower.len) return;

    var c = if (shift) map_upper[make] else map_lower[make];
    if (c == 0) return;
    if (caps and isAlpha(c)) c = flipCase(c);

    if (ctrl) {
        const cc = toCtrl(c);
        if (cc != 0) {
            push(cc);
            return;
        }
    }
    push(c);
}

/// Pop the next byte, or null if the buffer is empty.
pub fn pop() ?u8 {
    if (tail == head) return null;
    const c = ring[tail];
    tail = (tail + 1) % RING_SIZE;
    return c;
}

/// Block (with interrupts enabled) until a byte is available, then return it.
pub fn blockingPop() u8 {
    while (true) {
        if (pop()) |c| return c;
        asm volatile ("hlt");
    }
}
