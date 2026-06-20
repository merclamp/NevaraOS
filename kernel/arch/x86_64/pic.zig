//! Intel 8259A PIC driver.
//!
//! Remaps the master/slave PICs so hardware IRQs land on vectors 0x20..0x2F
//! (the default 0x08..0x0F overlaps CPU exception vectors). All lines start
//! masked; the kernel unmasks what it needs.

const PIC1_CMD: u16 = 0x20;
const PIC1_DATA: u16 = 0x21;
const PIC2_CMD: u16 = 0xA0;
const PIC2_DATA: u16 = 0xA1;

const ICW1_INIT: u8 = 0x10;
const ICW1_ICW4: u8 = 0x01;
const ICW4_8086: u8 = 0x01;
const EOI: u8 = 0x20;

/// Vector offset for IRQ0 (master). IRQ8 (slave) lands at OFFSET + 8.
pub const OFFSET: u8 = 0x20;

inline fn outb(port: u16, value: u8) void {
    asm volatile ("outb %[v], %[p]"
        :
        : [v] "{al}" (value),
          [p] "{dx}" (port),
    );
}

inline fn inb(port: u16) u8 {
    return asm volatile ("inb %[p], %[r]"
        : [r] "={al}" (-> u8),
        : [p] "{dx}" (port),
    );
}

/// A short delay; some PICs need time to settle between command writes.
inline fn ioWait() void {
    outb(0x80, 0);
}

/// Remap both PICs and mask every IRQ line.
pub fn init() void {
    // Start initialization sequence (cascade mode).
    outb(PIC1_CMD, ICW1_INIT | ICW1_ICW4);
    ioWait();
    outb(PIC2_CMD, ICW1_INIT | ICW1_ICW4);
    ioWait();
    // Vector offsets.
    outb(PIC1_DATA, OFFSET);
    ioWait();
    outb(PIC2_DATA, OFFSET + 8);
    ioWait();
    // Cascade wiring: master has a slave on IRQ2; tell the slave its identity.
    outb(PIC1_DATA, 0x04);
    ioWait();
    outb(PIC2_DATA, 0x02);
    ioWait();
    // 8086/88 mode.
    outb(PIC1_DATA, ICW4_8086);
    ioWait();
    outb(PIC2_DATA, ICW4_8086);
    ioWait();
    // Mask all lines.
    outb(PIC1_DATA, 0xFF);
    outb(PIC2_DATA, 0xFF);
}

/// Unmask (enable) a single IRQ line (0..15).
pub fn unmask(irq: u8) void {
    if (irq < 8) {
        const m = inb(PIC1_DATA) & ~(@as(u8, 1) << @as(u3, @intCast(irq)));
        outb(PIC1_DATA, m);
    } else {
        const m = inb(PIC2_DATA) & ~(@as(u8, 1) << @as(u3, @intCast(irq - 8)));
        outb(PIC2_DATA, m);
    }
}

/// Mask (disable) a single IRQ line (0..15).
pub fn mask(irq: u8) void {
    if (irq < 8) {
        const m = inb(PIC1_DATA) | (@as(u8, 1) << @as(u3, @intCast(irq)));
        outb(PIC1_DATA, m);
    } else {
        const m = inb(PIC2_DATA) | (@as(u8, 1) << @as(u3, @intCast(irq - 8)));
        outb(PIC2_DATA, m);
    }
}

/// Signal end-of-interrupt for the given IRQ line.
pub fn sendEOI(irq: u8) void {
    if (irq >= 8) outb(PIC2_CMD, EOI);
    outb(PIC1_CMD, EOI);
}
