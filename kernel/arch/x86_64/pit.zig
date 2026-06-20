//! Intel 8253/8254 PIT (Programmable Interval Timer).
//!
//! Channel 0 drives IRQ0. We program it in mode 3 (square wave) at a chosen
//! frequency to generate periodic timer interrupts for the scheduler.

const BASE_FREQ: u32 = 1_193_182; // PIT input clock, Hz
const CH0_DATA: u16 = 0x40;
const CMD: u16 = 0x43;

inline fn outb(port: u16, value: u8) void {
    asm volatile ("outb %[v], %[p]"
        :
        : [v] "{al}" (value),
          [p] "{dx}" (port),
    );
}

/// Program channel 0 to fire IRQ0 at approximately `hz` times per second.
pub fn init(hz: u32) void {
    const divisor: u32 = BASE_FREQ / hz;
    // Channel 0, access lobyte/hibyte, mode 3 (square wave), binary.
    outb(CMD, 0x36);
    outb(CH0_DATA, @intCast(divisor & 0xFF));
    outb(CH0_DATA, @intCast((divisor >> 8) & 0xFF));
}

/// Ticks since boot (incremented by IRQ0 at `hz` Hz).
pub var jiffies: u64 = 0;

/// Called from the IRQ0 handler every timer interrupt.
pub fn tick() void {
    jiffies += 1;
}
