//! Early serial logger over the 16550 UART (COM1, I/O port 0x3F8).
//! Used for kernel output before any console/framebuffer exists.

const COM1: u16 = 0x3F8;

inline fn outb(port: u16, value: u8) void {
    asm volatile ("outb %[value], %[port]"
        :
        : [value] "{al}" (value),
          [port] "{dx}" (port),
    );
}

inline fn inb(port: u16) u8 {
    return asm volatile ("inb %[port], %[ret]"
        : [ret] "={al}" (-> u8),
        : [port] "{dx}" (port),
    );
}

/// Initialize COM1: 38400 baud, 8N1, FIFO enabled.
pub fn init() void {
    outb(COM1 + 1, 0x00); // disable interrupts
    outb(COM1 + 3, 0x80); // enable DLAB (set baud divisor)
    outb(COM1 + 0, 0x03); // divisor low  byte (3 => 38400 baud)
    outb(COM1 + 1, 0x00); // divisor high byte
    outb(COM1 + 3, 0x03); // 8 bits, no parity, one stop bit
    outb(COM1 + 2, 0xC7); // enable FIFO, clear, 14-byte threshold
    outb(COM1 + 4, 0x0B); // RTS/DSR set, OUT2 enabled
}

inline fn transmitEmpty() bool {
    return (inb(COM1 + 5) & 0x20) != 0;
}

/// Write a single byte, blocking until the transmit holding register is free.
pub fn writeByte(byte: u8) void {
    while (!transmitEmpty()) {}
    outb(COM1, byte);
}