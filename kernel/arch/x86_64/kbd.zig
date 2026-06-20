//! PS/2 keyboard driver (i8042, scancode set 1).
//!
//! The IRQ1 handler reads a scancode from port 0x60, translates it to ASCII
//! (honoring shift), and pushes it into a ring buffer the tty layer drains.

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

fn push(c: u8) void {
    const next = (head + 1) % RING_SIZE;
    if (next == tail) return; // full: drop
    ring[head] = c;
    head = next;
}

/// Called from the IRQ1 handler.
pub fn onIrq() void {
    const code = inb(DATA);
    const released = (code & 0x80) != 0;
    const make = code & 0x7F;

    // Shift make/break (0x2A left, 0x36 right).
    if (make == 0x2A or make == 0x36) {
        shift = !released;
        return;
    }
    if (released) return;

    if (make < map_lower.len) {
        const c = if (shift) map_upper[make] else map_lower[make];
        if (c != 0) push(c);
    }
}

/// Pop the next ASCII byte, or null if the buffer is empty.
pub fn pop() ?u8 {
    if (tail == head) return null;
    const c = ring[tail];
    tail = (tail + 1) % RING_SIZE;
    return c;
}

const console = @import("console.zig");

/// Block (with interrupts enabled) until a key is available, then return it.
fn blockingPop() u8 {
    while (true) {
        if (pop()) |c| return c;
        asm volatile ("hlt");
    }
}

/// Canonical line read: echo input, handle backspace, return on Enter.
/// Returns the number of bytes written to `buf` (including the trailing '\n').
pub fn readLine(buf: []u8) usize {
    var n: usize = 0;
    asm volatile ("sti");
    while (true) {
        const c = blockingPop();
        switch (c) {
            '\n' => {
                console.writeByte('\n');
                if (n < buf.len) {
                    buf[n] = '\n';
                    n += 1;
                }
                break;
            },
            8, 127 => { // backspace / delete
                if (n > 0) {
                    n -= 1;
                    console.writeString("\x08 \x08"); // erase on screen
                }
            },
            else => {
                if (n < buf.len) {
                    buf[n] = c;
                    n += 1;
                    console.writeByte(c); // echo
                }
            },
        }
    }
    asm volatile ("cli");
    return n;
}
