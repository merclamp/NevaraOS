//! Framebuffer terminal — Linux VT-compatible subset.
//!
//! Font: VGA 8×16 (default8x16.psfu, same as Linux console default).
//! Supports: SGR with proper attribute flags (bold, reverse, underline),
//!   cursor movement, erase, scroll region, save/restore cursor,
//!   insert/delete lines, autowrap, ?25h/?25l cursor visibility.

const font = @import("../../font.zig");

pub const Framebuffer = struct {
    addr:   usize,
    pitch:  u32,
    width:  u32,
    height: u32,
    bpp:    u8,
};

const GLYPH_W: usize = 8;
const GLYPH_H: usize = 16;

const MAX_COLS: usize = 105;
const MAX_ROWS: usize = 40;

// Linux VT colour palette (same RGB values as linux/drivers/video/fbdev/core/fbcon.c)
const palette = [16]u32{
    0x00000000, // 0  black
    0x00AA0000, // 1  red
    0x0000AA00, // 2  green
    0x00AA5500, // 3  brown/yellow
    0x000000AA, // 4  blue
    0x00AA00AA, // 5  magenta
    0x0000AAAA, // 6  cyan
    0x00AAAAAA, // 7  light grey
    0x00555555, // 8  dark grey (bright black)
    0x00FF5555, // 9  bright red
    0x0055FF55, // 10 bright green
    0x00FFFF55, // 11 bright yellow
    0x005555FF, // 12 bright blue
    0x00FF55FF, // 13 bright magenta
    0x0055FFFF, // 14 bright cyan
    0x00FFFFFF, // 15 white
};

const DEFAULT_FG: u8 = 7;
const DEFAULT_BG: u8 = 0;

// Attribute flags (same model as Linux VT)
const ATTR_BOLD:      u8 = 0x01;
const ATTR_REVERSE:   u8 = 0x02;
const ATTR_UNDERLINE: u8 = 0x04;

const Cell = struct {
    ch:    u8 = ' ',
    fg:    u8 = DEFAULT_FG,
    bg:    u8 = DEFAULT_BG,
    attrs: u8 = 0,
};

var info:   Framebuffer = undefined;
var cols:   usize = 0;
var rows:   usize = 0;
var active: bool  = false;

var cells: [MAX_COLS * MAX_ROWS]Cell = undefined;

// Cursor
var cx: usize = 0;
var cy: usize = 0;
var cursor_visible: bool = true;

// Saved cursor (ESC[s / ESC[u)
var saved_cx:    usize = 0;
var saved_cy:    usize = 0;
var saved_fg:    u8 = DEFAULT_FG;
var saved_bg:    u8 = DEFAULT_BG;
var saved_attrs: u8 = 0;

// Scroll region (DECSTBM)
var scroll_top:    usize = 0;
var scroll_bottom: usize = 0; // inclusive last row

// Current attributes
var cur_fg:    u8 = DEFAULT_FG;
var cur_bg:    u8 = DEFAULT_BG;
var cur_attrs: u8 = 0;

// Autowrap
var autowrap: bool = true;
// Pending wrap: next char triggers newline before being placed
var pending_wrap: bool = false;

// ANSI escape parser
const ParseState = enum { normal, esc, csi, osc };
var state:      ParseState = .normal;
const MAX_PARAMS = 16;
var params:     [MAX_PARAMS]usize = undefined;
var nparams:    usize = 0;
var csi_priv:   bool = false; // '?' prefix seen

pub fn init(fb: Framebuffer) bool {
    if (fb.bpp != 32) return false;
    const c = fb.width  / GLYPH_W;
    const r = fb.height / GLYPH_H;
    if (c == 0 or r == 0 or c > MAX_COLS or r > MAX_ROWS) return false;
    info   = fb;
    cols   = c;
    rows   = r;
    scroll_top    = 0;
    scroll_bottom = rows - 1;
    resetState();
    active = true;
    for (cells[0 .. cols * rows]) |*cell| cell.* = .{};
    fillScreen(palette[DEFAULT_BG]);
    return true;
}

pub fn isActive() bool { return active; }

fn resetState() void {
    cx = 0; cy = 0;
    cur_fg    = DEFAULT_FG;
    cur_bg    = DEFAULT_BG;
    cur_attrs = 0;
    state     = .normal;
    autowrap  = true;
    pending_wrap = false;
    cursor_visible = true;
}

// ---- Pixel helpers ----------------------------------------------------------

inline fn pixelPtr(x: usize, y: usize) *volatile u32 {
    return @ptrFromInt(info.addr + y * info.pitch + x * 4);
}

fn fillScreen(color: u32) void {
    var y: usize = 0;
    while (y < info.height) : (y += 1) {
        var x: usize = 0;
        while (x < info.width) : (x += 1)
            pixelPtr(x, y).* = color;
    }
}

inline fn cellAt(x: usize, y: usize) *Cell { return &cells[y * cols + x]; }

// ---- Glyph rendering --------------------------------------------------------

fn resolvedColors(fg: u8, bg: u8, attrs: u8) struct { fg: u32, bg: u32 } {
    var rfg = palette[fg & 0xF];
    var rbg = palette[bg & 0xF];
    if (attrs & ATTR_REVERSE != 0) { const t = rfg; rfg = rbg; rbg = t; }
    return .{ .fg = rfg, .bg = rbg };
}

fn drawGlyph(ch: u8, ox: usize, oy: usize, fg: u32, bg: u32, attrs: u8) void {
    const glyph = font.basic[ch & 0x7F];
    var gy: usize = 0;
    while (gy < GLYPH_H) : (gy += 1) {
        const bits = glyph[gy];
        // Underline: force solid on last row of glyph
        const underline_row = (attrs & ATTR_UNDERLINE != 0) and gy == GLYPH_H - 2;
        var gx: usize = 0;
        while (gx < GLYPH_W) : (gx += 1) {
            const on = underline_row or ((bits >> @as(u3, @intCast(7 - gx))) & 1 != 0);
            pixelPtr(ox + gx, oy + gy).* = if (on) fg else bg;
        }
    }
}

fn drawCell(x: usize, y: usize) void {
    const cell = cellAt(x, y);
    const c = resolvedColors(cell.fg, cell.bg, cell.attrs);
    drawGlyph(cell.ch, x * GLYPH_W, y * GLYPH_H, c.fg, c.bg, cell.attrs);
}

// Draw cursor: underline bar like Linux VT default
fn drawCursorAt(x: usize, y: usize, show: bool) void {
    if (!cursor_visible) return;
    const cell = cellAt(x, y);
    const c = resolvedColors(cell.fg, cell.bg, cell.attrs);
    var fg = c.fg; var bg = c.bg;
    if (show) { const t = fg; fg = bg; bg = t; } // invert for cursor block
    drawGlyph(cell.ch, x * GLYPH_W, y * GLYPH_H, fg, bg, cell.attrs);
}

// ---- Screen operations ------------------------------------------------------

fn clearScreen() void {
    for (cells[0 .. cols * rows]) |*cell|
        cell.* = .{ .fg = cur_fg, .bg = cur_bg };
    fillScreen(palette[cur_bg]);
}

fn eraseRow(y: usize, x0: usize, x1: usize) void {
    var x = x0;
    while (x < x1 and x < cols) : (x += 1) {
        cellAt(x, y).* = .{ .fg = cur_fg, .bg = cur_bg };
        drawCell(x, y);
    }
}

fn eraseRange(y0: usize, x0: usize, y1: usize, x1: usize) void {
    if (y0 == y1) { eraseRow(y0, x0, x1); return; }
    eraseRow(y0, x0, cols);
    var y = y0 + 1;
    while (y < y1) : (y += 1) eraseRow(y, 0, cols);
    eraseRow(y1, 0, x1);
}

// Scroll up within [scroll_top..scroll_bottom] by n lines
fn scrollUp(n: usize) void {
    if (n == 0) return;
    const actual = @min(n, scroll_bottom - scroll_top + 1);
    // Pixel blit
    const src_row = scroll_top + actual;
    const dst_row = scroll_top;
    const copy_rows = (scroll_bottom - scroll_top + 1) -| actual;
    if (copy_rows > 0) {
        const src_off = src_row * GLYPH_H * info.pitch;
        const dst_off = dst_row * GLYPH_H * info.pitch;
        const nbytes  = copy_rows * GLYPH_H * info.pitch;
        var i: usize = 0;
        while (i < nbytes) : (i += 4) {
            @as(*volatile u32, @ptrFromInt(info.addr + dst_off + i)).* =
            @as(*volatile u32, @ptrFromInt(info.addr + src_off + i)).*;
        }
        // Cell grid
        var y = dst_row;
        while (y < dst_row + copy_rows) : (y += 1) {
            var x: usize = 0;
            while (x < cols) : (x += 1)
                cellAt(x, y).* = cellAt(x, y + actual).*;
        }
    }
    // Clear vacated rows
    var y = scroll_bottom + 1 - actual;
    while (y <= scroll_bottom) : (y += 1) eraseRow(y, 0, cols);
}

// Scroll down within [scroll_top..scroll_bottom] by n lines
fn scrollDown(n: usize) void {
    if (n == 0) return;
    const actual = @min(n, scroll_bottom - scroll_top + 1);
    const copy_rows = (scroll_bottom - scroll_top + 1) -| actual;
    if (copy_rows > 0) {
        const src_row = scroll_top;
        const dst_row = scroll_top + actual;
        const src_off = src_row * GLYPH_H * info.pitch;
        const dst_off = dst_row * GLYPH_H * info.pitch;
        const nbytes  = copy_rows * GLYPH_H * info.pitch;
        // Copy backwards to avoid overlap
        var i: usize = nbytes;
        while (i >= 4) {
            i -= 4;
            @as(*volatile u32, @ptrFromInt(info.addr + dst_off + i)).* =
            @as(*volatile u32, @ptrFromInt(info.addr + src_off + i)).*;
        }
        var y = dst_row + copy_rows;
        while (y > dst_row) {
            y -= 1;
            var x: usize = 0;
            while (x < cols) : (x += 1)
                cellAt(x, y).* = cellAt(x, y - actual).*;
        }
    }
    var y = scroll_top;
    while (y < scroll_top + actual) : (y += 1) eraseRow(y, 0, cols);
}

// ---- Character output -------------------------------------------------------

fn putChar_(ch: u8) void {
    if (pending_wrap and autowrap) {
        pending_wrap = false;
        cx = 0;
        cy += 1;
        if (cy > scroll_bottom) { cy = scroll_bottom; scrollUp(1); }
    }
    const cell = cellAt(cx, cy);
    cell.* = .{ .ch = ch, .fg = cur_fg, .bg = cur_bg, .attrs = cur_attrs };
    drawCell(cx, cy);
    if (cx + 1 >= cols) {
        pending_wrap = true;
    } else {
        cx += 1;
    }
}

fn newline() void {
    pending_wrap = false;
    cx = 0;  // LF implies CR in our terminal (matches console.zig behaviour)
    if (cy == scroll_bottom) {
        scrollUp(1);
    } else {
        cy = @min(cy + 1, rows - 1);
    }
}

// ---- SGR --------------------------------------------------------------------

fn handleSGR() void {
    const n = if (nparams == 0) @as(usize, 1) else nparams;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const p = if (i < nparams) params[i] else 0;
        switch (p) {
            0 => {
                cur_fg    = DEFAULT_FG;
                cur_bg    = DEFAULT_BG;
                cur_attrs = 0;
            },
            1 => {
                cur_attrs |= ATTR_BOLD;
                if (cur_fg < 8) cur_fg += 8;
            },
            4 => cur_attrs |= ATTR_UNDERLINE,
            7 => cur_attrs |= ATTR_REVERSE,
            22 => {
                cur_attrs &= ~ATTR_BOLD;
                if (cur_fg >= 8) cur_fg -= 8;
            },
            24 => cur_attrs &= ~ATTR_UNDERLINE,
            27 => cur_attrs &= ~ATTR_REVERSE,
            30...37 => cur_fg = @intCast(p - 30 + (if (cur_attrs & ATTR_BOLD != 0) @as(usize, 8) else 0)),
            38 => cur_fg = DEFAULT_FG,
            39 => cur_fg = DEFAULT_FG,
            40...47 => cur_bg = @intCast(p - 40),
            49 => cur_bg = DEFAULT_BG,
            90...97 => cur_fg = @intCast(p - 90 + 8),
            100...107 => cur_bg = @intCast(p - 100 + 8),
            else => {},
        }
    }
}

// ---- CSI dispatch -----------------------------------------------------------

fn param_(idx: usize, default: usize) usize {
    if (idx >= nparams or params[idx] == 0) return default;
    return params[idx];
}

fn execCSI(final: u8) void {
    if (csi_priv) {
        // Private sequences: ?25h/?25l (cursor on/off), ?7h/?7l (autowrap)
        switch (final) {
            'h' => {
                var i: usize = 0;
                while (i < @max(nparams, 1)) : (i += 1) {
                    switch (params[i]) {
                        25 => cursor_visible = true,
                        7  => autowrap = true,
                        else => {},
                    }
                }
            },
            'l' => {
                var i: usize = 0;
                while (i < @max(nparams, 1)) : (i += 1) {
                    switch (params[i]) {
                        25 => cursor_visible = false,
                        7  => autowrap = false,
                        else => {},
                    }
                }
            },
            else => {},
        }
        return;
    }

    switch (final) {
        // Cursor movement
        'A' => { cy -|= param_(0, 1); cy = @max(cy, scroll_top); },
        'B' => { cy = @min(cy + param_(0, 1), scroll_bottom); },
        'C' => { cx = @min(cx + param_(0, 1), cols - 1); pending_wrap = false; },
        'D' => { cx -|= param_(0, 1); pending_wrap = false; },
        'E' => { cy = @min(cy + param_(0, 1), rows - 1); cx = 0; },
        'F' => { cy -|= param_(0, 1); cx = 0; },
        'G' => { cx = @min(param_(0, 1) -| 1, cols - 1); },
        'H', 'f' => {
            cy = @min(param_(0, 1) -| 1, rows - 1);
            cx = @min(param_(1, 1) -| 1, cols - 1);
            pending_wrap = false;
        },
        // Erase
        'J' => switch (param_(0, 0)) {
            0 => eraseRange(cy, cx, rows - 1, cols),
            1 => eraseRange(0, 0, cy, cx + 1),
            2 => clearScreen(),
            else => {},
        },
        'K' => switch (param_(0, 0)) {
            0 => eraseRow(cy, cx, cols),
            1 => eraseRow(cy, 0, cx + 1),
            2 => eraseRow(cy, 0, cols),
            else => {},
        },
        // Scroll
        'S' => scrollUp(param_(0, 1)),
        'T' => scrollDown(param_(0, 1)),
        // Insert / delete lines
        'L' => scrollDown(param_(0, 1)),
        'M' => scrollUp(param_(0, 1)),
        // Insert / delete characters
        'P' => { // delete chars: shift left
            const n = @min(param_(0, 1), cols - cx);
            var x = cx;
            while (x + n < cols) : (x += 1) {
                cellAt(x, cy).* = cellAt(x + n, cy).*;
                drawCell(x, cy);
            }
            eraseRow(cy, x, cols);
        },
        '@' => { // insert blank chars: shift right
            const n = @min(param_(0, 1), cols - cx);
            var x = cols;
            while (x > cx + n) {
                x -= 1;
                cellAt(x, cy).* = cellAt(x - n, cy).*;
                drawCell(x, cy);
            }
            eraseRow(cy, cx, cx + n);
        },
        // Scroll region (DECSTBM)
        'r' => {
            const top = param_(0, 1) -| 1;
            const bot = param_(1, rows) -| 1;
            if (top < bot and bot < rows) {
                scroll_top    = top;
                scroll_bottom = bot;
            }
            cx = 0; cy = scroll_top;
        },
        // Save / restore cursor
        's' => { saved_cx = cx; saved_cy = cy; saved_fg = cur_fg; saved_bg = cur_bg; saved_attrs = cur_attrs; },
        'u' => { cx = saved_cx; cy = saved_cy; cur_fg = saved_fg; cur_bg = saved_bg; cur_attrs = saved_attrs; },
        // SGR
        'm' => handleSGR(),
        // Erase chars
        'X' => eraseRow(cy, cx, cx + param_(0, 1)),
        // Report cursor position
        'n' => {}, // DA / DSR — ignore, no bidirectional channel
        else => {},
    }
}

// ---- Process byte -----------------------------------------------------------

fn process(c: u8) void {
    switch (state) {
        .normal => switch (c) {
            0x1B => { state = .esc; },
            '\n', 0x0B, 0x0C => newline(), // LF, VT, FF
            '\r'  => { cx = 0; pending_wrap = false; },
            0x08  => { // BS: non-destructive
                if (pending_wrap) { pending_wrap = false; }
                else if (cx > 0) cx -= 1;
            },
            0x7F  => {}, // DEL: ignore
            '\t'  => { // HT: next tab stop (every 8 cols)
                const next = (cx + 8) & ~@as(usize, 7);
                while (cx < next and cx < cols) putChar_(' ');
            },
            0x20...0x7E => putChar_(c),
            0x07  => {}, // BEL: ignore
            0x0E, 0x0F => {}, // SO/SI: charset — ignore
            else  => {},
        },
        .esc => switch (c) {
            '[' => { state = .csi; nparams = 1; params[0] = 0; csi_priv = false; },
            ']' => { state = .osc; },
            'c' => { // RIS: full reset
                scroll_top = 0; scroll_bottom = rows - 1;
                resetState();
                clearScreen();
            },
            'D' => newline(),         // IND
            'E' => { cx = 0; newline(); }, // NEL
            'M' => {                  // RI: reverse index
                if (cy == scroll_top) scrollDown(1)
                else cy -|= 1;
            },
            '7' => { saved_cx = cx; saved_cy = cy; saved_fg = cur_fg; saved_bg = cur_bg; saved_attrs = cur_attrs; state = .normal; },
            '8' => { cx = saved_cx; cy = saved_cy; cur_fg = saved_fg; cur_bg = saved_bg; cur_attrs = saved_attrs; state = .normal; },
            else => { state = .normal; },
        },
        .osc => {
            // OSC: skip until ST (0x07 or ESC \)
            if (c == 0x07) state = .normal;
            // ESC \ handled next ESC cycle
        },
        .csi => switch (c) {
            '?' => { csi_priv = true; },
            '0'...'9' => {
                params[nparams - 1] = params[nparams - 1] * 10 + (c - '0');
            },
            ';' => {
                if (nparams < MAX_PARAMS) {
                    nparams += 1;
                    params[nparams - 1] = 0;
                }
            },
            0x40...0x7E => {
                execCSI(c);
                state = .normal;
            },
            else => { state = .normal; },
        },
    }
}

/// Feed one output byte through the terminal state machine.
pub fn putChar(c: u8) void {
    if (!active) return;
    // Hide cursor before any state change, redraw after.
    drawCursorAt(cx, cy, false);
    process(c);
    drawCursorAt(cx, cy, true);
}

/// Write a string (used by console.zig).
pub fn putString(s: []const u8) void {
    if (!active) return;
    drawCursorAt(cx, cy, false);
    for (s) |c| process(c);
    drawCursorAt(cx, cy, true);
}
