//! Kernel console: fans output to serial, VGA text mode, and the
//! Multiboot2 framebuffer (when available).
//!
//! VGA text mode (0xB8000, 80x25) is always enabled — it works on any
//! x86 hardware regardless of framebuffer availability.

const serial = @import("serial.zig");
const vga    = @import("vga.zig");
const fb     = @import("fb.zig");

/// Initialize serial and VGA text sinks. Both are always available.
pub fn init() void {
    serial.init();
    vga.init();
}

/// Enable on-screen output via a bootloader-provided framebuffer.
pub fn useFramebuffer(framebuffer: fb.Framebuffer) bool {
    return fb.init(framebuffer);
}

/// Save the interrupt flag and disable interrupts. Console output touches
/// shared framebuffer state (cursor position, escape-parser state, the cell
/// grid), so a timer preemption landing mid-write would corrupt it. Making each
/// write atomic w.r.t. interrupts keeps concurrent threads from clobbering it.
inline fn irqSave() u64 {
    return asm volatile (
        \\ pushfq
        \\ popq %[flags]
        \\ cli
        : [flags] "=r" (-> u64),
        :
        : .{ .memory = true });
}

inline fn irqRestore(flags: u64) void {
    if (flags & 0x200 != 0) asm volatile ("sti" ::: .{ .memory = true });
}

/// Emit one byte to every sink. Caller must hold the interrupt guard.
fn rawByte(c: u8) void {
    if (c == '\n') {
        serial.writeByte('\r');
        serial.writeByte('\n');
        vga.putChar('\n');
    } else {
        serial.writeByte(c);
        vga.putChar(c);
    }
    fb.putChar(c);
}

pub fn writeByte(c: u8) void {
    const flags = irqSave();
    defer irqRestore(flags);
    rawByte(c);
}

pub fn writeString(s: []const u8) void {
    const flags = irqSave();
    defer irqRestore(flags);
    for (s) |c| rawByte(c);
}

/// Write a 64-bit value as `0x` + 16 hex digits.
pub fn writeHex(value: u64) void {
    const digits = "0123456789abcdef";
    writeString("0x");
    var shift: u6 = 60;
    while (true) : (shift -= 4) {
        const nibble: u8 = @intCast((value >> shift) & 0xF);
        writeByte(digits[nibble]);
        if (shift == 0) break;
    }
}

/// Write an unsigned value in base-10.
pub fn writeDec(value: u64) void {
    if (value == 0) {
        writeByte('0');
        return;
    }
    var buf: [20]u8 = undefined;
    var i: usize = 0;
    var v = value;
    while (v > 0) : (v /= 10) {
        buf[i] = '0' + @as(u8, @intCast(v % 10));
        i += 1;
    }
    while (i > 0) {
        i -= 1;
        writeByte(buf[i]);
    }
}
