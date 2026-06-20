//! ATA (IDE) PIO driver for the primary master drive.
//!
//! QEMU exposes a PIIX3 IDE controller; a `-drive if=ide,index=0` disk is the
//! primary master at I/O ports 0x1F0-0x1F7. This is the simplest real block
//! device: 28-bit LBA, one 512-byte sector per transfer, polled (no DMA/IRQ).

const console = @import("console.zig");

pub const SECTOR_SIZE: usize = 512;

const DATA: u16 = 0x1F0;
const ERROR: u16 = 0x1F1;
const SECCOUNT: u16 = 0x1F2;
const LBA_LO: u16 = 0x1F3;
const LBA_MID: u16 = 0x1F4;
const LBA_HI: u16 = 0x1F5;
const DRIVE: u16 = 0x1F6;
const STATUS: u16 = 0x1F7;
const COMMAND: u16 = 0x1F7;
const CTRL: u16 = 0x3F6;

const ST_ERR: u8 = 0x01;
const ST_DRQ: u8 = 0x08;
const ST_SRV: u8 = 0x10;
const ST_DF: u8 = 0x20;
const ST_RDY: u8 = 0x40;
const ST_BSY: u8 = 0x80;

const CMD_READ: u8 = 0x20;
const CMD_WRITE: u8 = 0x30;
const CMD_FLUSH: u8 = 0xE7;

var present: bool = false;

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
inline fn inw(port: u16) u16 {
    return asm volatile ("inw %[p], %[r]"
        : [r] "={ax}" (-> u16),
        : [p] "{dx}" (port),
    );
}
inline fn outw(port: u16, value: u16) void {
    asm volatile ("outw %[v], %[p]"
        :
        : [v] "{ax}" (value),
          [p] "{dx}" (port),
    );
}

/// Brief 400ns settle after a drive/command select: read the alternate status
/// register four times.
inline fn delay400ns() void {
    _ = inb(CTRL);
    _ = inb(CTRL);
    _ = inb(CTRL);
    _ = inb(CTRL);
}

fn waitNotBusy() bool {
    var spins: usize = 0;
    while (spins < 1_000_000) : (spins += 1) {
        const s = inb(STATUS);
        if (s & ST_BSY == 0) return true;
    }
    return false;
}

fn waitDataReady() bool {
    var spins: usize = 0;
    while (spins < 1_000_000) : (spins += 1) {
        const s = inb(STATUS);
        if (s & ST_BSY != 0) continue;
        if (s & ST_ERR != 0 or s & ST_DF != 0) return false;
        if (s & ST_DRQ != 0) return true;
    }
    return false;
}

fn selectLba(lba: u32, count: u8) void {
    _ = waitNotBusy();
    outb(DRIVE, 0xE0 | @as(u8, @intCast((lba >> 24) & 0x0F))); // LBA, master
    delay400ns();
    outb(SECCOUNT, count);
    outb(LBA_LO, @intCast(lba & 0xFF));
    outb(LBA_MID, @intCast((lba >> 8) & 0xFF));
    outb(LBA_HI, @intCast((lba >> 16) & 0xFF));
}

/// Detect the primary master. Returns false if no drive responds.
pub fn init() bool {
    _ = waitNotBusy();
    outb(DRIVE, 0xE0);
    delay400ns();
    const s = inb(STATUS);
    present = (s != 0xFF and s != 0x00);
    if (present) {
        console.writeString("[ata] primary master present\n");
    } else {
        console.writeString("[ata] no primary master drive\n");
    }
    return present;
}

pub fn isPresent() bool {
    return present;
}

/// Read one 512-byte sector at `lba` into `buf`. Returns false on error.
pub fn readSector(lba: u32, buf: *[SECTOR_SIZE]u8) bool {
    if (!present) return false;
    selectLba(lba, 1);
    outb(COMMAND, CMD_READ);
    if (!waitDataReady()) return false;
    var i: usize = 0;
    while (i < SECTOR_SIZE / 2) : (i += 1) {
        const w = inw(DATA);
        buf[i * 2] = @intCast(w & 0xFF);
        buf[i * 2 + 1] = @intCast(w >> 8);
    }
    return true;
}

/// Write one 512-byte sector `buf` to `lba`. Returns false on error.
pub fn writeSector(lba: u32, buf: *const [SECTOR_SIZE]u8) bool {
    if (!present) return false;
    selectLba(lba, 1);
    outb(COMMAND, CMD_WRITE);
    if (!waitDataReady()) return false;
    var i: usize = 0;
    while (i < SECTOR_SIZE / 2) : (i += 1) {
        const w = @as(u16, buf[i * 2]) | (@as(u16, buf[i * 2 + 1]) << 8);
        outw(DATA, w);
    }
    // Flush the write cache.
    outb(COMMAND, CMD_FLUSH);
    _ = waitNotBusy();
    return true;
}
