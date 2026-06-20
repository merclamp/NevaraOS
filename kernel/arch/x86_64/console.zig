//! Kernel console: fans output out to the serial port and, once a framebuffer
//! is available, to the on-screen framebuffer text console. All kernel
//! subsystems log through here so output appears both on the wire and on the
//! monitor.

const serial = @import("serial.zig");
const fb = @import("fb.zig");

/// Initialize the always-available serial sink.
pub fn init() void {
    serial.init();
}

/// Enable on-screen output via a bootloader-provided framebuffer.
pub fn useFramebuffer(framebuffer: fb.Framebuffer) bool {
    return fb.init(framebuffer);
}

pub fn writeByte(c: u8) void {
    if (c == '\n') {
        serial.writeByte('\r');
        serial.writeByte('\n');
    } else {
        serial.writeByte(c);
    }
    fb.putChar(c);
}

pub fn writeString(s: []const u8) void {
    for (s) |c| writeByte(c);
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
