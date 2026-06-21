//! VGA text-mode console (80x25, colour, port I/O).
//!
//! The VGA text buffer at 0xB8000 is always available on x86 hardware
//! regardless of framebuffer or UEFI mode. Each cell is 2 bytes:
//! [char][attr] where attr = (bg<<4)|fg, colour 7 = light grey on black.
//!
//! This is used as a last-resort output sink so "Nevara OS" appears on
//! screen even when the Multiboot2 framebuffer is unavailable or broken.

const WIDTH:  usize = 80;
const HEIGHT: usize = 25;
const ATTR:   u8    = 0x07; // light grey on black
const BASE:   usize = 0xB8000;

var col: usize = 0;
var row: usize = 0;

inline fn outb(port: u16, val: u8) void {
    asm volatile ("outb %[v],%[p]" : : [v] "{al}" (val), [p] "{dx}" (port));
}

fn cellPtr(c: usize, r: usize) *volatile u16 {
    return @ptrFromInt(BASE + (r * WIDTH + c) * 2);
}

fn clearScreen() void {
    var r: usize = 0;
    while (r < HEIGHT) : (r += 1) {
        var c: usize = 0;
        while (c < WIDTH) : (c += 1) {
            cellPtr(c, r).* = (@as(u16, ATTR) << 8) | 0x20; // space
        }
    }
}

fn moveCursor() void {
    const pos: u16 = @intCast(row * WIDTH + col);
    outb(0x3D4, 14);
    outb(0x3D5, @truncate(pos >> 8));
    outb(0x3D4, 15);
    outb(0x3D5, @truncate(pos));
}

fn scroll() void {
    // Move all rows up by one.
    var r: usize = 1;
    while (r < HEIGHT) : (r += 1) {
        var c: usize = 0;
        while (c < WIDTH) : (c += 1) {
            cellPtr(c, r - 1).* = cellPtr(c, r).*;
        }
    }
    // Clear last row.
    var c: usize = 0;
    while (c < WIDTH) : (c += 1) {
        cellPtr(c, HEIGHT - 1).* = (@as(u16, ATTR) << 8) | 0x20;
    }
    row = HEIGHT - 1;
}

pub fn init() void {
    clearScreen();
    col = 0;
    row = 0;
    moveCursor();
}

pub fn putChar(ch: u8) void {
    switch (ch) {
        '\n' => {
            col = 0;
            row += 1;
            if (row >= HEIGHT) scroll();
        },
        '\r' => {
            col = 0;
        },
        0x08 => { // backspace
            if (col > 0) col -= 1;
            cellPtr(col, row).* = (@as(u16, ATTR) << 8) | 0x20;
        },
        else => {
            cellPtr(col, row).* = (@as(u16, ATTR) << 8) | ch;
            col += 1;
            if (col >= WIDTH) {
                col = 0;
                row += 1;
                if (row >= HEIGHT) scroll();
            }
        },
    }
    moveCursor();
}

pub fn writeString(s: []const u8) void {
    for (s) |c| putChar(c);
}
