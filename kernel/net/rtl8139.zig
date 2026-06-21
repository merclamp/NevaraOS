//! RTL8139 Ethernet driver.
//!
//! Uses PIO via the I/O BAR (BAR0). QEMU emulates this card with `-device rtl8139`.
//! TX: 4 descriptors of up to 1792 bytes each (polled, no DMA ring).
//! RX: 64 KiB + 16 B wrap ring, polled in the interrupt handler.
//!
//! Register map (all offsets from iobase):
//!   0x00-0x05  MAC address (read)
//!   0x08       Transmit Status 0-3 (u32, one per descriptor)
//!   0x10       Transmit Start Address 0-3 (u32)
//!   0x30       Receive Buffer Start Address (RBSTART, u32)
//!   0x37       Command register
//!   0x38       CAPR — current address of packet read (u16)
//!   0x3A       CBR  — current buffer address (u16)
//!   0x3C       Interrupt Mask Register (IMR, u16)
//!   0x3E       Interrupt Status Register (ISR, u16)
//!   0x40       Transmit Configuration (TCR, u32)
//!   0x44       Receive Configuration (RCR, u32)
//!   0x50       93C46 Command register (for EEPROM unlock)

const pci = @import("../arch/x86_64/pci.zig");
const console = @import("../arch/x86_64/console.zig");
const heap = @import("../mm/heap.zig");

// RTL8139 PCI vendor/device.
const VENDOR: u16 = 0x10EC;
const DEVICE: u16 = 0x8139;

// Register offsets.
const REG_MAC:       u16 = 0x00;
const REG_MAR:       u16 = 0x08; // multicast
const REG_TSD0:      u16 = 0x10; // TX status descriptor 0
const REG_TSAD0:     u16 = 0x20; // TX start address descriptor 0
const REG_RBSTART:   u16 = 0x30;
const REG_CMD:       u16 = 0x37;
const REG_CAPR:      u16 = 0x38;
const REG_CBR:       u16 = 0x3A;
const REG_IMR:       u16 = 0x3C;
const REG_ISR:       u16 = 0x3E;
const REG_TCR:       u16 = 0x40;
const REG_RCR:       u16 = 0x44;
const REG_CONFIG1:   u16 = 0x52;

// CMD register bits.
const CMD_RST: u8 = 0x10;
const CMD_RE:  u8 = 0x08; // Receiver Enable
const CMD_TE:  u8 = 0x04; // Transmitter Enable

// ISR/IMR bits.
const ISR_ROK: u16 = 0x0001; // Receive OK
const ISR_TOK: u16 = 0x0004; // Transmit OK
const ISR_RER: u16 = 0x0002; // Receive Error
const ISR_TER: u16 = 0x0008; // Transmit Error

// RX ring size: 64 KiB + 16 bytes for wrap-around safety.
const RX_BUF_SIZE: usize = 64 * 1024 + 16;
// TX buffers: 4 descriptors, each up to 1792 bytes (round up to page).
const TX_BUF_SIZE: usize  = 1792;
const TX_DESC_COUNT: usize = 4;

var iobase: u16 = 0;
var mac_addr: [6]u8 = .{0} ** 6;

var rx_buf: []u8 = &.{};
var tx_bufs: [TX_DESC_COUNT][]u8 = .{&.{}} ** TX_DESC_COUNT;
var tx_idx: usize = 0; // next TX descriptor to use
var rx_ptr: usize = 0; // byte offset into rx_buf where next packet starts

var initialized: bool = false;

// Callback invoked by the IRQ handler for each received frame.
// Set by net.zig before enabling the NIC.
pub var on_receive: ?*const fn (data: []const u8) void = null;

// ---- I/O helpers -----------------------------------------------------------

inline fn outb(port: u16, v: u8) void {
    asm volatile ("outb %[v], %[p]" : : [v] "{al}" (v), [p] "{dx}" (port));
}
inline fn outw(port: u16, v: u16) void {
    asm volatile ("outw %[v], %[p]" : : [v] "{ax}" (v), [p] "{dx}" (port));
}
inline fn outl(port: u16, v: u32) void {
    asm volatile ("outl %[v], %[p]" : : [v] "{eax}" (v), [p] "{dx}" (port));
}
inline fn inb(port: u16) u8 {
    return asm volatile ("inb %[p], %[r]" : [r] "={al}" (-> u8) : [p] "{dx}" (port));
}
inline fn inw(port: u16) u16 {
    return asm volatile ("inw %[p], %[r]" : [r] "={ax}" (-> u16) : [p] "{dx}" (port));
}
inline fn inl(port: u16) u32 {
    return asm volatile ("inl %[p], %[r]" : [r] "={eax}" (-> u32) : [p] "{dx}" (port));
}

fn reg8(off: u16) u16  { return iobase + off; }
fn reg16(off: u16) u16 { return iobase + off; }
fn reg32(off: u16) u16 { return iobase + off; }

// ---- Init ------------------------------------------------------------------

pub fn init() bool {
    const pdev = pci.find(VENDOR, DEVICE) orelse {
        console.writeString("[rtl8139] not found on PCI bus\n");
        return false;
    };

    // BAR0 bits[1:0] = 01 → I/O space; strip the low bits for the actual base.
    iobase = @intCast(pdev.bar0 & 0xFFFC);
    pci.enableIo(pdev.bus, pdev.dev, pdev.func);

    console.writeString("[rtl8139] found at PCI dev ");
    console.writeDec(pdev.dev);
    console.writeString(", iobase=0x");
    console.writeHex(iobase);
    console.writeString(", IRQ=");
    console.writeDec(pdev.irq);
    console.writeString("\n");

    // Power on.
    outb(reg8(REG_CONFIG1), 0x00);

    // Software reset: set RST bit, wait for it to clear.
    outb(reg8(REG_CMD), CMD_RST);
    var spin: usize = 0;
    while (inb(reg8(REG_CMD)) & CMD_RST != 0 and spin < 1_000_000) : (spin += 1) {}

    // Read MAC address from registers 0x00-0x05.
    for (&mac_addr, 0..) |*b, i| b.* = inb(iobase + @as(u16, @intCast(i)));
    console.writeString("[rtl8139] MAC ");
    for (mac_addr, 0..) |b, i| {
        if (i > 0) console.writeString(":");
        console.writeHex(b);
    }
    console.writeString("\n");

    // Allocate RX ring buffer (must be physically contiguous — we use the
    // kernel heap which maps contiguous virtual pages backed by contiguous
    // physical frames for small allocations).
    const alloc = heap.allocator();
    rx_buf = alloc.alloc(u8, RX_BUF_SIZE) catch {
        console.writeString("[rtl8139] rx_buf alloc failed\n");
        return false;
    };
    @memset(rx_buf, 0);

    // Allocate TX buffers.
    for (&tx_bufs) |*tb| {
        tb.* = alloc.alloc(u8, TX_BUF_SIZE) catch {
            console.writeString("[rtl8139] tx_buf alloc failed\n");
            return false;
        };
    }

    // Set RX buffer start address (physical address = virtual in identity map).
    outl(reg32(REG_RBSTART), @intCast(@intFromPtr(rx_buf.ptr)));

    // IMR: enable ROK + TOK + RER + TER.
    outw(reg16(REG_IMR), ISR_ROK | ISR_TOK | ISR_RER | ISR_TER);

    // RCR: accept broadcast + multicast + my-address, no wrap, 64K ring,
    //      max DMA burst 1024, FIFO threshold 16 bytes.
    // WRAP=0 → ring wraps, AB=accept broadcast, AM=accept multicast, APM=accept physical match
    outl(reg32(REG_RCR), 0x0000_8F00 | 0b1111); // AB|AM|APM|AAP, 64K buf, MXDMA=unlimited

    // TCR: IFG normal, max DMA 1024.
    outl(reg32(REG_TCR), 0x0000_0600);

    // Enable receiver + transmitter.
    outb(reg8(REG_CMD), CMD_RE | CMD_TE);

    rx_ptr = 0;
    initialized = true;

    console.writeString("[rtl8139] ready\n");
    return true;
}

pub fn isReady() bool { return initialized; }
pub fn macAddr() [6]u8 { return mac_addr; }

// ---- Transmit --------------------------------------------------------------

/// Send a raw Ethernet frame. `data` must be ≤ 1792 bytes.
/// Blocks (polls) until the descriptor is free and the packet is sent.
pub fn sendFrame(data: []const u8) void {
    if (!initialized) return;
    if (data.len > TX_BUF_SIZE) return;

    const idx = tx_idx;
    tx_idx = (tx_idx + 1) % TX_DESC_COUNT;

    const tb = tx_bufs[idx];
    @memcpy(tb[0..data.len], data);

    // Set physical address of this descriptor's buffer.
    const tsd_off: u16 = REG_TSAD0 + @as(u16, @intCast(idx * 4));
    outl(reg32(tsd_off), @intCast(@intFromPtr(tb.ptr)));

    // Write TX status: clear OWN (=1 means ready to send), set size.
    const ts_off: u16 = REG_TSD0 + @as(u16, @intCast(idx * 4));
    // TSD layout: bits[12:0] = size, bit[13]=OWN cleared → start DMA.
    outl(reg32(ts_off), @as(u32, @truncate(data.len)) & 0x1FFF);

    // Wait for TOK or TER.
    var spins: usize = 0;
    while (spins < 2_000_000) : (spins += 1) {
        const tsd = inl(reg32(ts_off));
        if (tsd & (1 << 15) != 0) break; // TOK
        if (tsd & (1 << 14) != 0) { console.writeString("[rtl8139] TX error\n"); break; }
    }
}

// ---- Receive (called from IRQ handler) -------------------------------------

/// Process all received frames in the ring buffer. Calls on_receive for each.
pub fn pollRx() void {
    if (!initialized) return;

    // ISR: check ROK.
    const isr = inw(reg16(REG_ISR));
    if (isr & (ISR_ROK | ISR_RER) == 0) return;
    outw(reg16(REG_ISR), isr); // ack all bits

    // Walk the ring buffer until CBR (current buffer address) wraps back.
    while (true) {
        // CBR is the NIC's write pointer; CAPR is our read pointer.
        // The NIC stops writing when CBR wraps around to CAPR.
        const cbr = inw(reg16(REG_CBR));
        const capr_reg = (rx_ptr + RX_BUF_SIZE - 16) % RX_BUF_SIZE;
        _ = capr_reg;

        // Check CMD.BUFE: buffer empty.
        if (inb(reg8(REG_CMD)) & 0x01 != 0) break; // BUFE=1 → empty
        _ = cbr;

        // Each packet in the ring:
        // [u16 status][u16 length (including 4-byte CRC)][data...][CRC]
        // All stored little-endian. Offset is always DWORD-aligned.
        if (rx_ptr + 4 > RX_BUF_SIZE) { rx_ptr = 0; break; }

        const status = (@as(u16, rx_buf[rx_ptr + 1]) << 8) | rx_buf[rx_ptr];
        const pkt_len = (@as(u16, rx_buf[rx_ptr + 3]) << 8) | rx_buf[rx_ptr + 2];

        if (status & 0x01 == 0) break; // ROK not set → not ready

        const data_len: usize = if (pkt_len > 4) pkt_len - 4 else 0; // strip CRC
        const frame_start = rx_ptr + 4;

        if (data_len > 0 and frame_start + data_len <= RX_BUF_SIZE) {
            if (on_receive) |cb| {
                cb(rx_buf[frame_start .. frame_start + data_len]);
            }
        }

        // Advance rx_ptr to next DWORD-aligned boundary.
        rx_ptr = (rx_ptr + 4 + pkt_len + 3) & ~@as(usize, 3);
        rx_ptr %= RX_BUF_SIZE;

        // Update CAPR (= rx_ptr - 0x10, always). The NIC uses CAPR+0x10 as
        // the free-space watermark.
        const capr: u16 = @intCast((rx_ptr + RX_BUF_SIZE - 0x10) % RX_BUF_SIZE);
        outw(reg16(REG_CAPR), capr);
    }
}

/// Called from the IRQ dispatcher for IRQ 11 (typical PCI INTA for RTL8139
/// on QEMU with the default PCI bridge).
pub fn onIrq() void {
    pollRx();
}
