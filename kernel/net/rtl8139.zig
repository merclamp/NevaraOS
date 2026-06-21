//! RTL8139 Ethernet driver.
//!
//! Uses PIO via the I/O BAR (BAR0). QEMU emulates this card with `-device rtl8139`.
//! TX: 4 descriptors of up to 1792 bytes each (polled, no DMA ring).
//! RX: 64 KiB + 16 B wrap ring, polled from the IRQ handler.
//!
//! DMA buffers are allocated from physical memory below 4 GiB (identity-mapped)
//! via pmm.allocLow32() so their physical address fits in the 32-bit DMA registers.

const pci = @import("../arch/x86_64/pci.zig");
const console = @import("../arch/x86_64/console.zig");
const pmm = @import("../mm/pmm.zig");

// RTL8139 PCI vendor/device.
const VENDOR: u16 = 0x10EC;
const DEVICE: u16 = 0x8139;

// Register offsets from iobase.
const REG_MAC:     u16 = 0x00;
const REG_TSAD0:   u16 = 0x20; // TX start address descriptor 0-3
const REG_TSD0:    u16 = 0x10; // TX status descriptor 0-3
const REG_RBSTART: u16 = 0x30; // RX buffer start (physical u32)
const REG_CMD:     u16 = 0x37;
const REG_CAPR:    u16 = 0x38;
const REG_CBR:     u16 = 0x3A;
const REG_IMR:     u16 = 0x3C;
const REG_ISR:     u16 = 0x3E;
const REG_TCR:     u16 = 0x40;
const REG_RCR:     u16 = 0x44;
const REG_CONFIG1: u16 = 0x52;

// CMD bits.
const CMD_RST: u8 = 0x10;
const CMD_RE:  u8 = 0x08;
const CMD_TE:  u8 = 0x04;

// ISR/IMR bits.
const ISR_ROK: u16 = 0x0001;
const ISR_TOK: u16 = 0x0004;
const ISR_RER: u16 = 0x0002;
const ISR_TER: u16 = 0x0008;

// RX ring: 64 KiB + 16 bytes for wrap safety. Must be contiguous below 4 GiB.
const RX_BUF_SIZE: usize = 64 * 1024 + 16;
const RX_PAGES:    usize = (RX_BUF_SIZE + pmm.PAGE_SIZE - 1) / pmm.PAGE_SIZE;

// TX: 4 descriptors, each 1 page (4096 bytes, max frame = 1792 bytes).
const TX_BUF_SIZE:   usize = 1792;
const TX_DESC_COUNT: usize = 4;

var iobase: u16 = 0;
var mac_addr: [6]u8 = .{0} ** 6;

// DMA buffers: physical == virtual (identity map, always < 4 GiB).
var rx_buf_phys: u32 = 0;
var rx_buf: [*]u8 = undefined;

var tx_phys: [TX_DESC_COUNT]u32 = .{0} ** TX_DESC_COUNT;
var tx_buf:  [TX_DESC_COUNT][*]u8 = undefined;
var tx_idx: usize = 0;

var rx_ptr: usize = 0; // byte offset in RX ring for the next unread packet

var initialized: bool = false;

pub var on_receive: ?*const fn (data: []const u8) void = null;

// ---- I/O port helpers -------------------------------------------------------

inline fn outb(port: u16, v: u8)  void { asm volatile ("outb %[v],%[p]" : : [v] "{al}" (v),  [p] "{dx}" (port)); }
inline fn outw(port: u16, v: u16) void { asm volatile ("outw %[v],%[p]" : : [v] "{ax}" (v),  [p] "{dx}" (port)); }
inline fn outl(port: u16, v: u32) void { asm volatile ("outl %[v],%[p]" : : [v] "{eax}" (v), [p] "{dx}" (port)); }
inline fn inb(port: u16) u8  { return asm volatile ("inb %[p],%[r]"  : [r] "={al}"  (-> u8)  : [p] "{dx}" (port)); }
inline fn inw(port: u16) u16 { return asm volatile ("inw %[p],%[r]"  : [r] "={ax}"  (-> u16) : [p] "{dx}" (port)); }
inline fn inl(port: u16) u32 { return asm volatile ("inl %[p],%[r]"  : [r] "={eax}" (-> u32) : [p] "{dx}" (port)); }

// ---- Init -------------------------------------------------------------------

pub fn init() bool {
    const pdev = pci.find(VENDOR, DEVICE) orelse {
        console.writeString("[rtl8139] not found on PCI bus\n");
        return false;
    };

    iobase = @intCast(pdev.bar0 & 0xFFFC);
    pci.enableIo(pdev.bus, pdev.dev, pdev.func);

    console.writeString("[rtl8139] PCI dev ");
    console.writeDec(pdev.dev);
    console.writeString(" iobase=0x");
    console.writeHex(iobase);
    console.writeString(" IRQ=");
    console.writeDec(pdev.irq);
    console.writeString("\n");

    // Power on.
    outb(iobase + REG_CONFIG1, 0x00);

    // Software reset.
    outb(iobase + REG_CMD, CMD_RST);
    var spin: usize = 0;
    while (inb(iobase + REG_CMD) & CMD_RST != 0 and spin < 1_000_000) : (spin += 1) {}

    // Read MAC (6 bytes at offset 0).
    for (&mac_addr, 0..) |*b, i| b.* = inb(iobase + @as(u16, @intCast(i)));

    console.writeString("[rtl8139] MAC ");
    for (mac_addr, 0..) |b, i| {
        if (i > 0) console.writeString(":");
        // Print as 2-digit hex.
        const digits = "0123456789abcdef";
        var tmp: [2]u8 = .{ digits[b >> 4], digits[b & 0xF] };
        _ = console.writeString(&tmp);
    }
    console.writeString("\n");

    // Allocate RX ring from DMA-safe memory (physical < 4 GiB, identity-mapped).
    const rx_phys_usize = pmm.allocLow32(RX_PAGES) orelse {
        console.writeString("[rtl8139] rx DMA alloc failed\n");
        return false;
    };
    rx_buf_phys = @intCast(rx_phys_usize);
    rx_buf = @ptrFromInt(rx_phys_usize);
    @memset(rx_buf[0..RX_BUF_SIZE], 0);

    // Allocate TX descriptors (1 page each).
    for (&tx_phys, &tx_buf) |*tp, *tb| {
        const p = pmm.allocLow32(1) orelse {
            console.writeString("[rtl8139] tx DMA alloc failed\n");
            return false;
        };
        tp.* = @intCast(p);
        tb.* = @ptrFromInt(p);
    }

    // Program the NIC.
    outl(iobase + REG_RBSTART, rx_buf_phys);
    outw(iobase + REG_IMR, ISR_ROK | ISR_TOK | ISR_RER | ISR_TER);
    // RCR: WRAP=0, 64K ring, MXDMA=unlimited, AB+AM+APM+AAP.
    outl(iobase + REG_RCR, 0x0000_8F00 | 0b1111);
    // TCR: IFG normal, MXDMA=2048.
    outl(iobase + REG_TCR, 0x0000_0600);
    // Enable RX + TX.
    outb(iobase + REG_CMD, CMD_RE | CMD_TE);

    rx_ptr = 0;
    initialized = true;
    console.writeString("[rtl8139] ready\n");
    return true;
}

pub fn isReady() bool { return initialized; }
pub fn macAddr() [6]u8 { return mac_addr; }

// ---- Transmit ---------------------------------------------------------------

pub fn sendFrame(data: []const u8) void {
    if (!initialized or data.len > TX_BUF_SIZE) return;

    const idx = tx_idx;
    tx_idx = (tx_idx + 1) % TX_DESC_COUNT;

    @memcpy(tx_buf[idx][0..data.len], data);

    // Write TX start address (physical).
    const tsad_off: u16 = REG_TSAD0 + @as(u16, @intCast(idx * 4));
    outl(iobase + tsad_off, tx_phys[idx]);

    // TSD: bit[12:0] = packet size, writing clears OWN bit -> NIC starts TX.
    const tsd_off: u16 = REG_TSD0 + @as(u16, @intCast(idx * 4));
    outl(iobase + tsd_off, @as(u32, @truncate(data.len)) & 0x1FFF);

    // Poll for TOK or TER (usually < 1 us in QEMU).
    var s: usize = 0;
    while (s < 2_000_000) : (s += 1) {
        const tsd = inl(iobase + tsd_off);
        if (tsd & (1 << 15) != 0) break; // TOK
        if (tsd & (1 << 14) != 0) { console.writeString("[rtl8139] TX err\n"); break; }
    }
}

// ---- Receive ----------------------------------------------------------------

pub fn pollRx() void {
    if (!initialized) return;

    const isr = inw(iobase + REG_ISR);
    if (isr & (ISR_ROK | ISR_RER) == 0) return;
    outw(iobase + REG_ISR, isr); // acknowledge

    // Walk ring until BUFE (buffer empty) is set.
    while (inb(iobase + REG_CMD) & 0x01 == 0) {
        if (rx_ptr + 4 > RX_BUF_SIZE) { rx_ptr = 0; break; }

        // Header: [u16 status LE][u16 length LE (includes 4-byte CRC)]
        const status = @as(u16, rx_buf[rx_ptr + 1]) << 8 | rx_buf[rx_ptr];
        const pkt_len = @as(u16, rx_buf[rx_ptr + 3]) << 8 | rx_buf[rx_ptr + 2];

        if (status & 0x01 == 0) break; // ROK not set

        const data_len: usize = if (pkt_len > 4) pkt_len - 4 else 0;
        const frame_start = rx_ptr + 4;

        if (data_len > 0 and frame_start + data_len <= RX_BUF_SIZE) {
            if (on_receive) |cb| cb(rx_buf[frame_start .. frame_start + data_len]);
        }

        // Advance to next DWORD-aligned boundary.
        rx_ptr = (rx_ptr + 4 + pkt_len + 3) & ~@as(usize, 3);
        rx_ptr %= RX_BUF_SIZE;

        // Update CAPR (our read pointer minus 0x10 as per datasheet).
        const capr: u16 = @intCast((rx_ptr + RX_BUF_SIZE - 0x10) % RX_BUF_SIZE);
        outw(iobase + REG_CAPR, capr);
    }
}

pub fn onIrq() void { pollRx(); }
