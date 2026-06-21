//! Linear-framebuffer terminal emulator.
//!
//! Renders the public-domain 8x8 font (scaled) into a GRUB-provided 32-bpp RGB
//! linear framebuffer and behaves like a small ANSI/VT100 terminal: a cell grid
//! with per-cell colour, a block cursor, and a CSI escape-sequence parser
//! (cursor movement, line/screen erase, and SGR colours). Only 32-bpp
//! framebuffers are supported (we request depth 32 in the Multiboot2 header);
//! other depths disable graphical output.

const font = @import("../../font.zig");

/// Framebuffer description handed to us by the bootloader.
pub const Framebuffer = struct {
    addr: usize,
    pitch: u32,
    width: u32,
    height: u32,
    bpp: u8,
};

const SCALE:   usize = 1;  // native pixels — no scaling
const GLYPH_W: usize = 8;  // 8 px wide
const GLYPH_H: usize = 16; // 16 px tall (VGA 8×16 font)

// 800×600 at 8×16: 100 cols × 37 rows.
const MAX_COLS: usize = 105;
const MAX_ROWS: usize = 40;


/// 16-colour ANSI palette (0-7 normal, 8-15 bright). Index 0 is pure black so
/// the default terminal background is black, not tinted.
const palette = [16]u32{
    0x00000000, // 0  black
    0x00CC4040, // 1  red
    0x0040CC60, // 2  green
    0x00CCAA40, // 3  yellow
    0x004060CC, // 4  blue
    0x00AA50CC, // 5  magenta
    0x0040AACC, // 6  cyan
    0x00CCCCCC, // 7  white / light grey
    0x00555560, // 8  bright black (grey)
    0x00FF6060, // 9  bright red
    0x0060FF80, // 10 bright green
    0x00FFE060, // 11 bright yellow
    0x006080FF, // 12 bright blue
    0x00D080FF, // 13 bright magenta
    0x0060D0FF, // 14 bright cyan
    0x00FFFFFF, // 15 bright white
};

const DEFAULT_FG: u8 = 7;
const DEFAULT_BG: u8 = 0;

const Cell = struct {
    ch: u8 = ' ',
    fg: u8 = DEFAULT_FG,
    bg: u8 = DEFAULT_BG,
};

var info: Framebuffer = undefined;
var cols: usize = 0;
var rows: usize = 0;
var active: bool = false;

var cells: [MAX_COLS * MAX_ROWS]Cell = undefined;

// Cursor position and the position where the block is currently drawn.
var cx: usize = 0;
var cy: usize = 0;
var draw_cx: usize = 0;
var draw_cy: usize = 0;

// Current SGR attributes applied to newly written cells.
var cur_fg: u8 = DEFAULT_FG;
var cur_bg: u8 = DEFAULT_BG;
var bold: bool = false;

// ---- ANSI escape parser state ----------------------------------------------
const ParseState = enum { normal, esc, csi };
var state: ParseState = .normal;
const MAX_PARAMS = 8;
var params: [MAX_PARAMS]usize = undefined;
var nparams: usize = 0;
var have_param: bool = false;

/// Initialize the console. Returns false (and stays inactive) for unsupported
/// framebuffer formats or geometry that overflows the static cell grid.
pub fn init(fb: Framebuffer) bool {
    if (fb.bpp != 32) return false;
    const c = fb.width / GLYPH_W;
    const r = fb.height / GLYPH_H;
    if (c == 0 or r == 0 or c > MAX_COLS or r > MAX_ROWS) return false;

    info = fb;
    cols = c;
    rows = r;
    cx = 0;
    cy = 0;
    cur_fg = DEFAULT_FG;
    cur_bg = DEFAULT_BG;
    bold = false;
    state = .normal;
    active = true;

    for (cells[0 .. cols * rows]) |*cell| cell.* = .{};
    clearScreen();
    drawCursor();
    return true;
}

pub fn isActive() bool {
    return active;
}

inline fn pixelPtr(x: usize, y: usize) *volatile u32 {
    return @ptrFromInt(info.addr + y * info.pitch + x * 4);
}

inline fn cellAt(x: usize, y: usize) *Cell {
    return &cells[y * cols + x];
}

/// Draw a single glyph cell with explicit foreground/background colours.
/// Font is VGA 8×16, MSB = leftmost pixel.
fn drawGlyph(ch: u8, ox: usize, oy: usize, fg: u32, bg: u32) void {
    const glyph = font.basic[ch & 0x7F];
    var gy: usize = 0;
    while (gy < GLYPH_H) : (gy += 1) {
        const bits = glyph[gy];
        var gx: usize = 0;
        while (gx < GLYPH_W) : (gx += 1) {
            // MSB first: bit 7 is leftmost pixel.
            const on = (bits >> @as(u3, @intCast(7 - gx))) & 1 != 0;
            pixelPtr(ox + gx, oy + gy).* = if (on) fg else bg;
        }
    }
}

/// Render the stored cell at (x,y) using its own colours.
fn drawCell(x: usize, y: usize) void {
    const cell = cellAt(x, y);
    drawGlyph(cell.ch, x * GLYPH_W, y * GLYPH_H, palette[cell.fg], palette[cell.bg]);
}

/// Draw the block cursor over the cell at the current position (inverted).
fn drawCursor() void {
    const cell = cellAt(cx, cy);
    drawGlyph(cell.ch, cx * GLYPH_W, cy * GLYPH_H, palette[cell.bg], palette[cell.fg]);
    draw_cx = cx;
    draw_cy = cy;
}

/// Restore the cell the cursor was last drawn over to its normal appearance.
fn hideCursor() void {
    drawCell(draw_cx, draw_cy);
}

fn clearScreen() void {
    for (cells[0 .. cols * rows]) |*cell| cell.* = .{ .fg = cur_fg, .bg = cur_bg };
    var y: usize = 0;
    while (y < info.height) : (y += 1) {
        var x: usize = 0;
        while (x < info.width) : (x += 1) {
            pixelPtr(x, y).* = palette[cur_bg];
        }
    }
}

fn scroll() void {
    // Blit the visible pixels up by one glyph row (fast path), then clear the
    // freed bottom row.
    const row_bytes = info.pitch * GLYPH_H;
    const total = info.pitch * info.height;
    const moved = total - row_bytes;

    var i: usize = 0;
    while (i < moved) : (i += 4) {
        const src: *volatile u32 = @ptrFromInt(info.addr + row_bytes + i);
        @as(*volatile u32, @ptrFromInt(info.addr + i)).* = src.*;
    }
    while (i < total) : (i += 4) {
        @as(*volatile u32, @ptrFromInt(info.addr + i)).* = palette[DEFAULT_BG];
    }

    // Shift the cell grid up one row and clear the last row.
    var y: usize = 1;
    while (y < rows) : (y += 1) {
        var x: usize = 0;
        while (x < cols) : (x += 1) cellAt(x, y - 1).* = cellAt(x, y).*;
    }
    var x: usize = 0;
    while (x < cols) : (x += 1) cellAt(x, rows - 1).* = .{};

    cy = rows - 1;
}

fn newline() void {
    cx = 0;
    cy += 1;
    if (cy >= rows) scroll();
}

fn putGlyph(ch: u8) void {
    cellAt(cx, cy).* = .{ .ch = ch, .fg = cur_fg, .bg = cur_bg };
    drawCell(cx, cy);
    cx += 1;
    if (cx >= cols) newline();
}

/// Erase a span of cells on the current row [x0, x1) to the current background.
fn eraseCells(x0: usize, x1: usize) void {
    var x = x0;
    while (x < x1 and x < cols) : (x += 1) {
        cellAt(x, cy).* = .{ .fg = cur_fg, .bg = cur_bg };
        drawCell(x, cy);
    }
}

fn handleSGR() void {
    if (nparams == 0) {
        cur_fg = DEFAULT_FG;
        cur_bg = DEFAULT_BG;
        bold = false;
        return;
    }
    var i: usize = 0;
    while (i < nparams) : (i += 1) {
        const p = params[i];
        switch (p) {
            0 => {
                cur_fg = DEFAULT_FG;
                cur_bg = DEFAULT_BG;
                bold = false;
            },
            1 => {
                bold = true;
                if (cur_fg < 8) cur_fg += 8;
            },
            22 => {
                bold = false;
                if (cur_fg >= 8) cur_fg -= 8;
            },
            7 => {
                const t = cur_fg;
                cur_fg = cur_bg;
                cur_bg = t;
            },
            30...37 => cur_fg = @intCast(p - 30 + (if (bold) @as(usize, 8) else 0)),
            90...97 => cur_fg = @intCast(p - 90 + 8),
            39 => cur_fg = DEFAULT_FG,
            40...47 => cur_bg = @intCast(p - 40),
            100...107 => cur_bg = @intCast(p - 100 + 8),
            49 => cur_bg = DEFAULT_BG,
            else => {},
        }
    }
}

fn param(idx: usize, default: usize) usize {
    if (idx >= nparams or params[idx] == 0) return default;
    return params[idx];
}

fn execCSI(final: u8) void {
    switch (final) {
        'A' => cy -= @min(cy, param(0, 1)),
        'B' => cy = @min(rows - 1, cy + param(0, 1)),
        'C' => cx = @min(cols - 1, cx + param(0, 1)),
        'D' => cx -= @min(cx, param(0, 1)),
        'G' => cx = @min(cols - 1, param(0, 1) - 1),
        'H', 'f' => {
            cy = @min(rows - 1, param(0, 1) - 1);
            cx = @min(cols - 1, param(1, 1) - 1);
        },
        'J' => {
            const mode = param(0, 0);
            switch (mode) {
                0 => { // cursor to end of screen
                    eraseCells(cx, cols);
                    var y = cy + 1;
                    while (y < rows) : (y += 1) {
                        var x: usize = 0;
                        while (x < cols) : (x += 1) {
                            cellAt(x, y).* = .{ .fg = cur_fg, .bg = cur_bg };
                            drawCell(x, y);
                        }
                    }
                },
                2 => {
                    clearScreen();
                    cx = 0;
                    cy = 0;
                },
                else => {},
            }
        },
        'K' => {
            const mode = param(0, 0);
            switch (mode) {
                0 => eraseCells(cx, cols), // cursor to EOL
                1 => eraseCells(0, cx + 1), // BOL to cursor
                2 => eraseCells(0, cols), // whole line
                else => {},
            }
        },
        'm' => handleSGR(),
        else => {},
    }
}

fn process(c: u8) void {
    switch (state) {
        .normal => switch (c) {
            0x1B => state = .esc,
            '\n' => newline(),
            '\r' => cx = 0,
            0x08 => {
                if (cx > 0) cx -= 1; // non-destructive backspace
            },
            '\t' => {
                const next = (cx + 4) & ~@as(usize, 3);
                while (cx < next and cx < cols) putGlyph(' ');
            },
            0x20...0x7E => putGlyph(c),
            else => {},
        },
        .esc => {
            if (c == '[') {
                state = .csi;
                nparams = 0;
                have_param = false;
                params[0] = 0;
            } else {
                state = .normal;
            }
        },
        .csi => {
            switch (c) {
                '0'...'9' => {
                    if (nparams == 0) nparams = 1;
                    params[nparams - 1] = params[nparams - 1] * 10 + (c - '0');
                    have_param = true;
                },
                ';' => {
                    if (nparams < MAX_PARAMS) {
                        nparams += 1;
                        params[nparams - 1] = 0;
                    }
                    have_param = false;
                },
                0x40...0x7E => {
                    execCSI(c);
                    state = .normal;
                },
                else => state = .normal,
            }
        },
    }
}

/// Feed one output byte through the terminal state machine.
pub fn putChar(c: u8) void {
    if (!active) return;
    hideCursor();
    process(c);
    drawCursor();
}
