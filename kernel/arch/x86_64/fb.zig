//! Linear-framebuffer text console.
//!
//! Renders the public-domain 8x8 font (scaled) into a GRUB-provided RGB linear
//! framebuffer. Only 32-bpp framebuffers are supported (we request depth 32 in
//! the Multiboot2 header); other depths disable graphical output.

const font = @import("../../font.zig");

/// Framebuffer description handed to us by the bootloader.
pub const Framebuffer = struct {
    addr: usize,
    pitch: u32,
    width: u32,
    height: u32,
    bpp: u8,
};

const SCALE: usize = 2; // 8x8 glyph -> 16x16 cell
const GLYPH_W: usize = 8 * SCALE;
const GLYPH_H: usize = 8 * SCALE;

const FG: u32 = 0x00CCCCCC; // light grey
const BG: u32 = 0x00101018; // near-black with a faint blue tint

var info: Framebuffer = undefined;
var cols: usize = 0;
var rows: usize = 0;
var cx: usize = 0;
var cy: usize = 0;
var active: bool = false;

/// Initialize the console. Returns false (and stays inactive) for unsupported
/// framebuffer formats.
pub fn init(fb: Framebuffer) bool {
    if (fb.bpp != 32) return false;
    info = fb;
    cols = fb.width / GLYPH_W;
    rows = fb.height / GLYPH_H;
    cx = 0;
    cy = 0;
    active = true;
    clear();
    return true;
}

pub fn isActive() bool {
    return active;
}

inline fn pixelPtr(x: usize, y: usize) *volatile u32 {
    return @ptrFromInt(info.addr + y * info.pitch + x * 4);
}

fn clear() void {
    var y: usize = 0;
    while (y < info.height) : (y += 1) {
        var x: usize = 0;
        while (x < info.width) : (x += 1) {
            pixelPtr(x, y).* = BG;
        }
    }
}

fn drawGlyph(c: u8, ox: usize, oy: usize) void {
    const glyph = font.basic[c & 0x7F];
    var gy: usize = 0;
    while (gy < 8) : (gy += 1) {
        const bits = glyph[gy];
        var gx: usize = 0;
        while (gx < 8) : (gx += 1) {
            const on = (bits >> @as(u3, @intCast(gx))) & 1 != 0;
            const color: u32 = if (on) FG else BG;
            var sy: usize = 0;
            while (sy < SCALE) : (sy += 1) {
                var sx: usize = 0;
                while (sx < SCALE) : (sx += 1) {
                    pixelPtr(ox + gx * SCALE + sx, oy + gy * SCALE + sy).* = color;
                }
            }
        }
    }
}

fn scroll() void {
    const row_bytes = info.pitch * GLYPH_H;
    const total = info.pitch * info.height;
    const moved = total - row_bytes;

    var i: usize = 0;
    while (i < moved) : (i += 4) {
        const src: *volatile u32 = @ptrFromInt(info.addr + row_bytes + i);
        @as(*volatile u32, @ptrFromInt(info.addr + i)).* = src.*;
    }
    while (i < total) : (i += 4) {
        @as(*volatile u32, @ptrFromInt(info.addr + i)).* = BG;
    }
    cy = rows - 1;
}

fn newline() void {
    cx = 0;
    cy += 1;
    if (cy >= rows) scroll();
}

pub fn putChar(c: u8) void {
    if (!active) return;
    switch (c) {
        '\n' => newline(),
        '\r' => cx = 0,
        '\t' => {
            const next = (cx + 4) & ~@as(usize, 3);
            while (cx < next and cx < cols) : (cx += 1) {
                drawGlyph(' ', cx * GLYPH_W, cy * GLYPH_H);
            }
        },
        else => {
            drawGlyph(c, cx * GLYPH_W, cy * GLYPH_H);
            cx += 1;
            if (cx >= cols) newline();
        },
    }
}
