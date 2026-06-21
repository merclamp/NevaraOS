//! ext4 read-write driver (extent-based, no journal, no checksums).
//!
//! Targets the specific mke2fs invocation used to build rootfs.ext4:
//!   mke2fs -t ext4 -b 1024 -O ^has_journal,^metadata_csum,^64bit,^dir_index
//!
//! Supported:
//!   Read: superblock, GDT, inodes, extent trees (depth 0..2), dir entries
//!   Write: alloc/free blocks and inodes, write file data, create/unlink
//!          dir entries, create files and directories
//!
//! Limitations:
//!   - Depth-1 extent index supported for writing (covers ~hundreds of MiB).
//!   - No journal: writes go directly to disk.
//!   - No metadata checksums.
//!   - No htree directories (dir_index feature disabled in image).


const std = @import("std");
const ata = @import("../arch/x86_64/ata.zig");
const console = @import("../arch/x86_64/console.zig");
const pit = @import("../arch/x86_64/pit.zig");

// Drive is determined at mount time by scanning all ATA positions.
// 0 = primary master (default for QEMU and most real hardware).
var active_drive: u1 = 0;
const SECTOR: u32 = 512;
const SB_OFFSET: u32 = 1024; // superblock byte offset on disk
const EXT4_MAGIC: u16 = 0xEF53;
const EXT_MAGIC: u16 = 0xF30A; // extent header magic
const ROOT_INO: u32 = 2;
const MAX_BLOCK_SIZE: usize = 4096;
const MAX_GROUPS: usize = 32; // enough for up to 32 * 8192 * 1024 = 256 MiB

// ---- helpers -----------------------------------------------------------------

inline fn rU16(b: []const u8, o: usize) u16 {
    return std.mem.readInt(u16, b[o..][0..2], .little);
}
inline fn rU32(b: []const u8, o: usize) u32 {
    return std.mem.readInt(u32, b[o..][0..4], .little);
}
inline fn wU16(b: []u8, o: usize, v: u16) void {
    std.mem.writeInt(u16, b[o..][0..2], v, .little);
}
inline fn wU32(b: []u8, o: usize, v: u32) void {
    std.mem.writeInt(u32, b[o..][0..4], v, .little);
}

// ---- on-disk state ----------------------------------------------------------

var mounted = false;
var block_size: u32 = 0;
var inodes_per_group: u32 = 0;
var inode_size: u32 = 0;
var first_data_block: u32 = 0;
var desc_size: u32 = 32;
var blocks_per_group: u32 = 0;
var num_groups: u32 = 0;
var total_blocks: u32 = 0;
var total_inodes: u32 = 0;

// Superblock cached in RAM (1024 bytes at SB_OFFSET).
var sb_cache: [1024]u8 = undefined;
// GDT cached in RAM (one descriptor per group, each desc_size bytes).
// We support up to MAX_GROUPS groups.
var gdt_cache: [MAX_GROUPS * 64]u8 = undefined; // 64 bytes ≥ any desc_size
var gdt_dirty: bool = false;
var sb_dirty: bool = false;

// Scratch block buffer for I/O.
var blk: [MAX_BLOCK_SIZE]u8 = undefined;
// Second scratch buffer for extent tree lookups.
var extblk: [MAX_BLOCK_SIZE]u8 = undefined;
// Inode buffer (inode_size bytes, max 256 here).
var inobuf: [256]u8 = undefined;

// ---- low-level I/O ----------------------------------------------------------

// All public functions that touch global scratch buffers (inobuf, blk, extblk)
// must run with interrupts disabled to prevent concurrent access from a
// preempted concurrent exec() in another process.
inline fn irqSave() u64 {
    return asm volatile (
        \\ pushfq
        \\ popq %[f]
        \\ cli
        : [f] "=r" (-> u64),
        :
        : .{ .memory = true });
}
inline fn irqRestore(flags: u64) void {
    if (flags & 0x200 != 0) asm volatile ("sti" ::: .{ .memory = true });
}


fn writeSector(lba: u32, buf: *const [SECTOR]u8) bool {
    return ata.writeSectorOn(active_drive, lba, buf);
}

/// Read a filesystem block (block_size bytes) into `out`.
fn readBlock(block: u32, out: []u8) bool {
    const spb = block_size / SECTOR;
    var k: u32 = 0;
    while (k < spb) : (k += 1) {
        var sec: [SECTOR]u8 = undefined;
        if (!ata.readSectorOn(active_drive, block * spb + k, &sec)) return false;
        @memcpy(out[k * SECTOR ..][0..SECTOR], sec[0..SECTOR]);
    }
    return true;
}

/// Write a filesystem block (block_size bytes) from `data`.
fn writeBlock(block: u32, data: []const u8) bool {
    const spb = block_size / SECTOR;
    var k: u32 = 0;
    while (k < spb) : (k += 1) {
        var sec: [SECTOR]u8 = undefined;
        @memcpy(sec[0..SECTOR], data[k * SECTOR ..][0..SECTOR]);
        if (!writeSector(block * spb + k, &sec)) return false;
    }
    return true;
}

/// Flush the superblock cache to disk.
fn flushSb() void {
    if (!sb_dirty) return;
    // Superblock lives at byte 1024 → sectors 2 and 3 (for 512-byte sectors).
    const lba0: u32 = SB_OFFSET / SECTOR;
    var s: [SECTOR]u8 = undefined;
    @memcpy(s[0..SECTOR], sb_cache[0..SECTOR]);
    _ = writeSector(lba0, &s);
    @memcpy(s[0..SECTOR], sb_cache[SECTOR..1024]);
    _ = writeSector(lba0 + 1, &s);
    sb_dirty = false;
}

/// Flush the GDT cache to disk.
fn flushGdt() void {
    if (!gdt_dirty) return;
    // GDT starts in the block immediately after the superblock.
    const gdt_block = first_data_block + 1;
    const gdt_bytes = num_groups * desc_size;
    // Write whole blocks that cover the GDT.
    var byte_off: u32 = 0;
    while (byte_off < gdt_bytes) {
        const blk_idx = gdt_block + byte_off / block_size;
        // Read the block first (GDT might not fill it entirely).
        if (!readBlock(blk_idx, blk[0..block_size])) break;
        // Overwrite the relevant slice.
        const blk_off = byte_off % block_size;
        const copy = @min(block_size - blk_off, gdt_bytes - byte_off);
        @memcpy(blk[blk_off .. blk_off + copy], gdt_cache[byte_off .. byte_off + copy]);
        _ = writeBlock(blk_idx, blk[0..block_size]);
        byte_off += copy;
    }
    gdt_dirty = false;
}

// ---- GDT helpers -------------------------------------------------------------

fn gdtEntry(group: u32) []u8 {
    const off = group * desc_size;
    return gdt_cache[off .. off + desc_size];
}

fn gdtBlockBitmap(group: u32) u32 { return rU32(gdtEntry(group), 0); }
fn gdtInodeBitmap(group: u32) u32 { return rU32(gdtEntry(group), 4); }
fn gdtInodeTable(group: u32)  u32 { return rU32(gdtEntry(group), 8); }
fn gdtFreeBlocks(group: u32) u16 { return rU16(gdtEntry(group), 12); }
fn gdtFreeInodes(group: u32) u16 { return rU16(gdtEntry(group), 14); }
fn gdtUsedDirs(group: u32)   u16 { return rU16(gdtEntry(group), 16); }

fn setGdtFreeBlocks(group: u32, v: u16) void { wU16(gdtEntry(group), 12, v); gdt_dirty = true; }
fn setGdtFreeInodes(group: u32, v: u16) void { wU16(gdtEntry(group), 14, v); gdt_dirty = true; }
fn setGdtUsedDirs(group: u32, v: u16)   void { wU16(gdtEntry(group), 16, v); gdt_dirty = true; }

// ---- superblock free-count helpers -------------------------------------------

fn sbFreeBlocks() u32 { return rU32(&sb_cache, 12); }
fn sbFreeInodes() u32 { return rU32(&sb_cache, 16); }
fn setSbFreeBlocks(v: u32) void { wU32(&sb_cache, 12, v); sb_dirty = true; }
fn setSbFreeInodes(v: u32) void { wU32(&sb_cache, 16, v); sb_dirty = true; }

// ---- mount ------------------------------------------------------------------

pub fn mount() bool {
    if (mounted) return true;
    // Try primary master (0) then primary slave (1).
    // On SATA-in-IDE-compat both are scanned.
    for ([_]u1{ 0, 1 }) |drv| {
        if (!ata.isPresentOn(drv)) continue;
        active_drive = drv;
        if (mountDrive()) return true;
    }
    return false;
}

fn mountDrive() bool {
    if (!ata.isPresentOn(active_drive)) return false;

    var s0: [SECTOR]u8 = undefined;
    var s1: [SECTOR]u8 = undefined;
    if (!ata.readSectorOn(active_drive, SB_OFFSET / SECTOR, &s0)) return false;
    if (!ata.readSectorOn(active_drive, SB_OFFSET / SECTOR + 1, &s1)) return false;
    @memcpy(sb_cache[0..SECTOR], s0[0..SECTOR]);
    @memcpy(sb_cache[SECTOR..1024], s1[0..SECTOR]);

    if (rU16(&sb_cache, 56) != EXT4_MAGIC) return false;

    const log_bs = rU32(&sb_cache, 24);
    block_size = @as(u32, 1024) << @intCast(log_bs);
    if (block_size > MAX_BLOCK_SIZE) return false;

    inodes_per_group = rU32(&sb_cache, 40);
    inode_size       = rU16(&sb_cache, 88);
    if (inode_size == 0) inode_size = 128;
    if (inode_size > 256) inode_size = 256; // cap to our buffer

    first_data_block = rU32(&sb_cache, 20);
    blocks_per_group = rU32(&sb_cache, 32);
    total_blocks     = rU32(&sb_cache, 4);
    total_inodes     = rU32(&sb_cache, 0);

    const incompat = rU32(&sb_cache, 96);
    desc_size = if (incompat & 0x80 != 0) rU16(&sb_cache, 254) else 32;
    if (desc_size == 0) desc_size = 32;
    if (desc_size > 64) desc_size = 64;

    num_groups = (total_blocks + blocks_per_group - 1) / blocks_per_group;
    if (num_groups > MAX_GROUPS) num_groups = MAX_GROUPS;

    // Load GDT into cache.
    const gdt_block = first_data_block + 1;
    const gdt_bytes = num_groups * desc_size;
    var byte_off: u32 = 0;
    while (byte_off < gdt_bytes) {
        const blk_idx = gdt_block + byte_off / block_size;
        if (!readBlock(blk_idx, blk[0..block_size])) return false;
        const blk_off = byte_off % block_size;
        const copy = @min(block_size - blk_off, gdt_bytes - byte_off);
        @memcpy(gdt_cache[byte_off .. byte_off + copy], blk[blk_off .. blk_off + copy]);
        byte_off += copy;
    }

    mounted = true;
    console.writeString("[ext4] mounted read-write\n");
    return true;
}

// ---- inode I/O --------------------------------------------------------------

/// Load inode `ino` into `inobuf`. Returns false on error.
fn readInode(ino: u32) bool {
    const group = (ino - 1) / inodes_per_group;
    const index = (ino - 1) % inodes_per_group;
    if (group >= num_groups) return false;

    const inode_table = gdtInodeTable(group);
    const inode_byte  = index * inode_size;
    const itbl_blk    = inode_table + inode_byte / block_size;
    const itbl_off    = inode_byte % block_size;
    if (!readBlock(itbl_blk, blk[0..block_size])) return false;
    @memcpy(inobuf[0..inode_size], blk[itbl_off .. itbl_off + inode_size]);
    return true;
}

/// Write `inobuf` back to inode `ino` on disk.
fn writeInode(ino: u32) bool {
    const group = (ino - 1) / inodes_per_group;
    const index = (ino - 1) % inodes_per_group;
    if (group >= num_groups) return false;

    const inode_table = gdtInodeTable(group);
    const inode_byte  = index * inode_size;
    const itbl_blk    = inode_table + inode_byte / block_size;
    const itbl_off    = inode_byte % block_size;
    if (!readBlock(itbl_blk, blk[0..block_size])) return false;
    @memcpy(blk[itbl_off .. itbl_off + inode_size], inobuf[0..inode_size]);
    return writeBlock(itbl_blk, blk[0..block_size]);
}

inline fn inoMode() u16  { return rU16(&inobuf, 0); }
inline fn inoSize() u32  { return rU32(&inobuf, 4); }
inline fn inoLinks() u16 { return rU16(&inobuf, 26); }
inline fn inoBlocks() u32 { return rU32(&inobuf, 28); } // in 512-byte units

fn setInoSize(v: u32)   void { wU32(&inobuf, 4, v); }
fn setInoLinks(v: u16)  void { wU16(&inobuf, 26, v); }
fn setInoBlocks(v: u32) void { wU32(&inobuf, 28, v); }

/// Current time in seconds since boot (good enough for relative timestamps).
fn nowSecs() u32 { return @truncate(pit.jiffies / 100); }

fn setInoAtime(v: u32) void { wU32(&inobuf,  8, v); }
fn setInoMtime(v: u32) void { wU32(&inobuf, 16, v); }
fn setInoCtime(v: u32) void { wU32(&inobuf, 24, v); }
fn inoModeFull() u16   { return rU16(&inobuf, 0); }

pub fn isDirMode(mode: u16) bool { return (mode & 0xF000) == 0x4000; }

// ---- extent tree (read) -----------------------------------------------------

fn extentLookup(logical: u32) ?u32 {
    if (rU16(&inobuf, 40) != EXT_MAGIC) return null;
    return extentSearch(inobuf[40 .. 40 + 60], logical, 0);
}

fn extentSearch(node: []const u8, logical: u32, level: u32) ?u32 {
    const entries = rU16(node, 2);
    const depth   = rU16(node, 6);
    var i: usize = 0;
    if (depth == 0) {
        while (i < entries) : (i += 1) {
            const e        = node[12 + i * 12 ..];
            const ee_block = rU32(e, 0);
            const ee_len   = rU16(e, 4) & 0x7FFF;
            const ee_start = rU32(e, 8);
            if (logical >= ee_block and logical < ee_block + ee_len)
                return ee_start + (logical - ee_block);
        }
        return null;
    }
    if (level > 2) return null;
    var chosen: u32 = 0;
    var found = false;
    while (i < entries) : (i += 1) {
        const e        = node[12 + i * 12 ..];
        const ei_block = rU32(e, 0);
        if (ei_block <= logical) {
            chosen = rU32(e, 4);
            found = true;
        }
    }
    if (!found) return null;
    if (!readBlock(chosen, extblk[0..block_size])) return null;
    if (rU16(&extblk, 0) != EXT_MAGIC) return null;
    return extentSearch(extblk[0..block_size], logical, level + 1);
}

// ---- block allocator --------------------------------------------------------

/// Allocate one free block. Searches all groups. Returns 0 on failure.
fn allocBlock() u32 {
    var g: u32 = 0;
    while (g < num_groups) : (g += 1) {
        if (gdtFreeBlocks(g) == 0) continue;
        const bmap_blk = gdtBlockBitmap(g);
        if (!readBlock(bmap_blk, blk[0..block_size])) continue;

        // Find a free bit (0 = free).
        var byte: usize = 0;
        while (byte < block_size) : (byte += 1) {
            if (blk[byte] == 0xFF) continue;
            var bit: u3 = 0;
            while (true) : (bit += 1) {
                if (blk[byte] & (@as(u8, 1) << bit) == 0) {
                    // Mark allocated.
                    blk[byte] |= @as(u8, 1) << bit;
                    _ = writeBlock(bmap_blk, blk[0..block_size]);
                    // Update free counts.
                    setGdtFreeBlocks(g, gdtFreeBlocks(g) - 1);
                    setSbFreeBlocks(sbFreeBlocks() - 1);
                    flushGdt();
                    flushSb();
                    const blkno = first_data_block +
                        g * blocks_per_group +
                        @as(u32, @intCast(byte * 8 + bit));
                    // Zero the new block.
                    @memset(blk[0..block_size], 0);
                    _ = writeBlock(blkno, blk[0..block_size]);
                    return blkno;
                }
                if (bit == 7) break;
            }
        }
    }
    return 0; // no space
}

/// Free a block back into the bitmap.
fn freeBlock(blkno: u32) void {
    if (blkno < first_data_block) return;
    const rel = blkno - first_data_block;
    const g   = rel / blocks_per_group;
    const idx = rel % blocks_per_group;
    if (g >= num_groups) return;

    const bmap_blk = gdtBlockBitmap(g);
    if (!readBlock(bmap_blk, blk[0..block_size])) return;
    const byte: usize = idx / 8;
    const bit:  u3    = @intCast(idx % 8);
    blk[byte] &= ~(@as(u8, 1) << bit);
    _ = writeBlock(bmap_blk, blk[0..block_size]);
    setGdtFreeBlocks(g, gdtFreeBlocks(g) + 1);
    setSbFreeBlocks(sbFreeBlocks() + 1);
    flushGdt();
    flushSb();
}

// ---- inode allocator --------------------------------------------------------

/// Allocate a free inode. Returns 0 on failure.
fn allocInodeNum(is_dir: bool) u32 {
    var g: u32 = 0;
    while (g < num_groups) : (g += 1) {
        if (gdtFreeInodes(g) == 0) continue;
        const ibmap_blk = gdtInodeBitmap(g);
        if (!readBlock(ibmap_blk, blk[0..block_size])) continue;

        var byte: usize = 0;
        while (byte < inodes_per_group / 8) : (byte += 1) {
            if (blk[byte] == 0xFF) continue;
            var bit: u3 = 0;
            while (true) : (bit += 1) {
                if (blk[byte] & (@as(u8, 1) << bit) == 0) {
                    blk[byte] |= @as(u8, 1) << bit;
                    _ = writeBlock(ibmap_blk, blk[0..block_size]);
                    setGdtFreeInodes(g, gdtFreeInodes(g) - 1);
                    setSbFreeInodes(sbFreeInodes() - 1);
                    if (is_dir) setGdtUsedDirs(g, gdtUsedDirs(g) + 1);
                    flushGdt();
                    flushSb();
                    return g * inodes_per_group + @as(u32, @intCast(byte * 8 + bit)) + 1;
                }
                if (bit == 7) break;
            }
        }
    }
    return 0;
}

/// Free inode `ino` back into the bitmap.
fn freeInodeNum(ino: u32, is_dir: bool) void {
    const g   = (ino - 1) / inodes_per_group;
    const idx = (ino - 1) % inodes_per_group;
    if (g >= num_groups) return;

    const ibmap_blk = gdtInodeBitmap(g);
    if (!readBlock(ibmap_blk, blk[0..block_size])) return;
    const byte: usize = idx / 8;
    const bit:  u3    = @intCast(idx % 8);
    blk[byte] &= ~(@as(u8, 1) << bit);
    _ = writeBlock(ibmap_blk, blk[0..block_size]);
    setGdtFreeInodes(g, gdtFreeInodes(g) + 1);
    setSbFreeInodes(sbFreeInodes() + 1);
    if (is_dir) {
        if (gdtUsedDirs(g) > 0) setGdtUsedDirs(g, gdtUsedDirs(g) - 1);
    }
    flushGdt();
    flushSb();
}

// ---- extent tree write (depth 0 and 1) --------------------------------------
//
// Ext4 extent structure (each entry 12 bytes):
//   Leaf (ee): ee_block(u32), ee_len(u16), ee_start_hi(u16), ee_start_lo(u32)
//   Index(ei): ei_block(u32), ei_leaf_lo(u32), ei_leaf_hi(u16), padding(u16)
// Header (12 bytes): eh_magic, eh_entries, eh_max, eh_depth, eh_generation
//
// In-inode i_block: 60 bytes = 12-byte header + 4×12-byte slots (depth=0 max=4).
// At depth=1 the in-inode holds index entries (ei_block, ei_leaf_lo) pointing
// to leaf blocks, each of which holds (block_size/12 - 1) leaf extents.
// With 1 KiB blocks: 85 leaves per block × 32767 blocks per extent ≈ 2.7 GiB.
// We support up to 3 index entries (i_block slots after the header).

// leafAppend: try to append `phys` (logical block `logical`) to a leaf node
// stored in `leaf_buf`.  Returns true on success.
fn leafAppend(leaf_buf: []u8, phys: u32, logical: u32) bool {
    const entries = rU16(leaf_buf, 2);
    const max_ent = rU16(leaf_buf, 4);
    if (entries >= max_ent) return false;

    // Try run-length merge with last extent.
    if (entries > 0) {
        const last = leaf_buf[12 + (@as(usize, entries) - 1) * 12 ..];
        const lb  = rU32(last, 0);
        const len = rU16(last, 4) & 0x7FFF;
        const pb  = rU32(last, 8);
        if (logical == lb + len and phys == pb + len and len < 0x7FFF) {
            wU16(@constCast(last), 4, len + 1);
            return true;
        }
    }
    // New leaf entry.
    const slot = leaf_buf[12 + @as(usize, entries) * 12 ..];
    wU32(@constCast(slot), 0, logical);
    wU16(@constCast(slot), 4, 1);
    wU16(@constCast(slot), 6, 0);
    wU32(@constCast(slot), 8, phys);
    wU16(leaf_buf, 2, entries + 1);
    return true;
}

// leafMax: how many extent leaves fit in one block.
fn leafMax() u16 {
    return @intCast(block_size / 12 - 1);
}

/// Append a new physical block `phys` (logical `logical`) to the extent tree
/// in `inobuf`.  Handles depth=0 (in-inode flat) and depth=1 (one index level).
/// Returns false only on fatal error (no space, I/O failure).
fn extentAppend(phys: u32, logical: u32) bool {
    const hdr = inobuf[40 .. 40 + 60];

    // ---- initialise if empty ----
    if (rU16(hdr, 0) != EXT_MAGIC) {
        wU16(@constCast(hdr), 0, EXT_MAGIC);
        wU16(@constCast(hdr), 2, 0);
        wU16(@constCast(hdr), 4, 4);
        wU16(@constCast(hdr), 6, 0); // depth=0
        wU32(@constCast(hdr), 8, 0);
    }

    const depth = rU16(hdr, 6);

    // ---- depth=0: try fast path ----
    if (depth == 0) {
        const entries = rU16(hdr, 2);
        const max_ent = rU16(hdr, 4);
        if (entries < max_ent) {
            // Fast path: still room in in-inode.
            if (entries > 0) {
                const last = @constCast(hdr[12 + (@as(usize, entries) - 1) * 12 ..]);
                const lb  = rU32(last, 0);
                const len = rU16(last, 4) & 0x7FFF;
                const pb  = rU32(last, 8);
                if (logical == lb + len and phys == pb + len and len < 0x7FFF) {
                    wU16(last, 4, len + 1);
                    return true;
                }
            }
            const slot = @constCast(hdr[12 + @as(usize, entries) * 12 ..]);
            wU32(slot, 0, logical);
            wU16(slot, 4, 1);
            wU16(slot, 6, 0);
            wU32(slot, 8, phys);
            wU16(@constCast(hdr), 2, entries + 1);
            return true;
        }

        // In-inode is full at depth=0 — upgrade to depth=1.
        // 1. Allocate a leaf block and copy the 4 existing extents into it.
        const leaf0 = allocBlock();
        if (leaf0 == 0) return false;
        @memset(extblk[0..block_size], 0);
        wU16(&extblk, 0, EXT_MAGIC);
        wU16(&extblk, 2, 4);           // entries = 4
        wU16(&extblk, 4, leafMax());
        wU16(&extblk, 6, 0);           // depth=0 (leaf)
        wU32(&extblk, 8, 0);
        @memcpy(extblk[12..12 + 4 * 12], hdr[12..12 + 4 * 12]);
        if (!writeBlock(leaf0, extblk[0..block_size])) { freeBlock(leaf0); return false; }

        // 2. Rewrite in-inode as depth=1 index node with one index entry.
        wU16(@constCast(hdr), 2, 1);   // entries = 1
        wU16(@constCast(hdr), 4, 3);   // max = 3 index entries
        wU16(@constCast(hdr), 6, 1);   // depth = 1
        // Write index entry 0: ei_block=0, ei_leaf_lo=leaf0.
        const idx0 = @constCast(hdr[12..]);
        wU32(idx0, 0, 0);       // ei_block
        wU32(idx0, 4, leaf0);   // ei_leaf_lo
        wU16(idx0, 8, 0);       // ei_leaf_hi
        wU16(idx0, 10, 0);      // padding
    }

    // ---- depth=1 ----
    {
        const entries = rU16(hdr, 2);
        const max_idx = rU16(hdr, 4);

        // Find the last index entry and try to append to its leaf block.
        if (entries > 0) {
            const last_idx = hdr[12 + (@as(usize, entries) - 1) * 12 ..];
            const leaf_phys = rU32(last_idx, 4); // ei_leaf_lo
            if (!readBlock(leaf_phys, extblk[0..block_size])) return false;
            if (leafAppend(extblk[0..block_size], phys, logical)) {
                return writeBlock(leaf_phys, extblk[0..block_size]);
            }
        }

        // Leaf is full — allocate a new leaf block.
        if (entries >= max_idx) return false; // index also full

        const new_leaf = allocBlock();
        if (new_leaf == 0) return false;
        @memset(extblk[0..block_size], 0);
        wU16(&extblk, 0, EXT_MAGIC);
        wU16(&extblk, 2, 0);
        wU16(&extblk, 4, leafMax());
        wU16(&extblk, 6, 0);
        wU32(&extblk, 8, 0);
        if (!leafAppend(extblk[0..block_size], phys, logical)) { freeBlock(new_leaf); return false; }
        if (!writeBlock(new_leaf, extblk[0..block_size])) { freeBlock(new_leaf); return false; }

        // Add index entry for new leaf.
        const new_idx = @constCast(hdr[12 + @as(usize, entries) * 12 ..]);
        wU32(new_idx, 0, logical); // ei_block = first logical block in this leaf
        wU32(new_idx, 4, new_leaf);
        wU16(new_idx, 8, 0);
        wU16(new_idx, 10, 0);
        wU16(@constCast(hdr), 2, entries + 1);
        return true;
    }
}

/// Free all data blocks belonging to the extent tree currently in `inobuf`.
/// Handles depth=0 and depth=1; also frees index leaf blocks themselves.
fn freeExtentTree() void {
    const hdr = inobuf[40 .. 40 + 60];
    if (rU16(hdr, 0) != EXT_MAGIC) return;
    const depth   = rU16(hdr, 6);
    const entries = rU16(hdr, 2);
    if (depth == 0) {
        var i: usize = 0;
        while (i < entries) : (i += 1) {
            const e      = hdr[12 + i * 12 ..];
            const start  = rU32(e, 8);
            const len    = rU16(e, 4) & 0x7FFF;
            var k: u32 = 0;
            while (k < len) : (k += 1) freeBlock(start + k);
        }
    } else if (depth == 1) {
        var i: usize = 0;
        while (i < entries) : (i += 1) {
            const idx_e     = hdr[12 + i * 12 ..];
            const leaf_phys = rU32(idx_e, 4);
            if (!readBlock(leaf_phys, extblk[0..block_size])) continue;
            const leaf_ents = rU16(&extblk, 2);
            var j: usize = 0;
            while (j < leaf_ents) : (j += 1) {
                const e     = extblk[12 + j * 12 ..];
                const start = rU32(e, 8);
                const len   = rU16(e, 4) & 0x7FFF;
                var k: u32 = 0;
                while (k < len) : (k += 1) freeBlock(start + k);
            }
            freeBlock(leaf_phys);
        }
    }
}

// ---- file I/O ---------------------------------------------------------------

/// Read a regular file's contents into `out`. Returns bytes read.
pub fn readFile(ino: u32, out: []u8) usize {
    if (!mounted or !readInode(ino)) return 0;
    const size = @min(@as(usize, inoSize()), out.len);
    var done: usize = 0;
    var lblock: u32 = 0;
    while (done < size) : (lblock += 1) {
        const chunk = @min(@as(usize, block_size), size - done);
        if (extentLookup(lblock)) |phys| {
            if (!readBlock(phys, blk[0..block_size])) break;
            @memcpy(out[done..][0..chunk], blk[0..chunk]);
        } else {
            @memset(out[done..][0..chunk], 0);
        }
        done += chunk;
    }
    return done;
}

/// Write `data` to file `ino`, truncating or extending as needed.
/// Returns number of bytes written, or 0 on error.
pub fn writeFile(ino: u32, data: []const u8) usize {
    if (!mounted or !readInode(ino)) return 0;

    // Free all existing data blocks (handles depth 0 and 1).
    freeExtentTree();
    // Reinitialise i_block extent header.
    @memset(inobuf[40 .. 40 + 60], 0);

    // Write new data block by block.
    var done: usize = 0;
    var lbl: u32 = 0;
    while (done < data.len) : (lbl += 1) {
        const phys = allocBlock();
        if (phys == 0) break;
        if (!extentAppend(phys, lbl)) { freeBlock(phys); break; }
        const chunk = @min(@as(usize, block_size), data.len - done);
        @memset(blk[0..block_size], 0);
        @memcpy(blk[0..chunk], data[done .. done + chunk]);
        if (!writeBlock(phys, blk[0..block_size])) break;
        done += chunk;
    }

    // Update inode: size, block count, timestamps.
    setInoSize(@intCast(done));
    const n_blks: u32 = (@as(u32, @intCast(done)) + block_size - 1) / block_size;
    setInoBlocks(n_blks * (block_size / 512));
    const ts = nowSecs();
    setInoMtime(ts);
    setInoCtime(ts);
    _ = writeInode(ino);
    return done;
}

// ---- directory operations ---------------------------------------------------

/// Append a directory entry to `dir_ino` (name, child inode, file type).
/// ftype: 1=regular, 2=directory.
pub fn createDirEntry(dir_ino: u32, name: []const u8, child_ino: u32, ftype: u8) bool {
    if (!mounted or !readInode(dir_ino)) return false;
    if (!isDirMode(inoMode())) return false;

    const needed_len: usize = (8 + name.len + 3) & ~@as(usize, 3); // 4-aligned

    // Scan existing blocks for space in a dirent's rec_len padding.
    var dir_size = inoSize();
    var lblock: u32 = 0;
    var pos: u32 = 0;
    while (pos < dir_size) : (lblock += 1) {
        const phys = extentLookup(lblock) orelse {
            pos += block_size;
            continue;
        };
        if (!readBlock(phys, blk[0..block_size])) return false;
        var off: usize = 0;
        while (off + 8 <= block_size) {
            const ent     = blk[off..];
            const rec_len = rU16(ent, 4);
            if (rec_len < 8) break;
            const name_len = ent[6];
            const real_len: usize = (8 + name_len + 3) & ~@as(usize, 3);
            const slack    = @as(usize, rec_len) - real_len;
            if (slack >= needed_len) {
                // Fit in the slack space.
                // Shrink existing entry to its real size.
                wU16(ent, 4, @intCast(real_len));
                // Write new entry after it.
                const new_ent = blk[off + real_len ..];
                wU32(new_ent, 0, child_ino);
                wU16(new_ent, 4, @intCast(slack));
                new_ent[6] = @intCast(name.len);
                new_ent[7] = ftype;
                @memcpy(new_ent[8 .. 8 + name.len], name);
                return writeBlock(phys, blk[0..block_size]);
            }
            off += rec_len;
        }
        pos += block_size;
    }

    // Need a new block for the directory.
    const phys = allocBlock();
    if (phys == 0) return false;

    // Append new extent.
    if (!readInode(dir_ino)) return false;
    if (!extentAppend(phys, lblock)) { freeBlock(phys); return false; }

    // Write the single entry filling the whole block.
    @memset(blk[0..block_size], 0);
    wU32(&blk, 0, child_ino);
    wU16(&blk, 4, @intCast(block_size));
    blk[6] = @intCast(name.len);
    blk[7] = ftype;
    @memcpy(blk[8 .. 8 + name.len], name);
    if (!writeBlock(phys, blk[0..block_size])) { freeBlock(phys); return false; }

    // Update dir inode size.
    dir_size += block_size;
    setInoSize(dir_size);
    const n_blks: u32 = dir_size / block_size;
    setInoBlocks(n_blks * (block_size / 512));
    return writeInode(dir_ino);
}

/// Remove the directory entry with `name` from `dir_ino`.
/// Returns the inode number of the removed entry, or 0 on failure.
pub fn removeDirEntry(dir_ino: u32, name: []const u8) u32 {
    if (!mounted or !readInode(dir_ino)) return 0;
    if (!isDirMode(inoMode())) return 0;

    const dir_size = inoSize();
    var lblock: u32 = 0;
    var pos: u32 = 0;
    while (pos < dir_size) : (lblock += 1) {
        const phys = extentLookup(lblock) orelse {
            pos += block_size;
            continue;
        };
        if (!readBlock(phys, blk[0..block_size])) return 0;
        var off: usize = 0;
        var prev_off: usize = 0;
        while (off + 8 <= block_size) {
            const ent      = blk[off..];
            const eino     = rU32(ent, 0);
            const rec_len  = rU16(ent, 4);
            if (rec_len < 8) break;
            const nl = ent[6];
            if (eino != 0 and nl == name.len and
                std.mem.eql(u8, ent[8 .. 8 + nl], name))
            {
                // Merge this entry's rec_len into the previous one, or zero it.
                if (off == 0) {
                    // First entry in block: zero inode.
                    wU32(ent, 0, 0);
                } else {
                    // Extend previous entry to absorb this one.
                    const prev = blk[prev_off..];
                    const prev_rec = rU16(prev, 4);
                    wU16(prev, 4, prev_rec + rec_len);
                }
                _ = writeBlock(phys, blk[0..block_size]);
                return eino;
            }
            prev_off = off;
            off += rec_len;
        }
        pos += block_size;
    }
    return 0;
}

// ---- create / unlink --------------------------------------------------------

/// Create a regular file named `name` in directory `dir_ino`.
/// Returns the new inode number, or 0 on error.
pub fn createFile(dir_ino: u32, name: []const u8, mode: u16) u32 {
    if (!mounted) return 0;
    const ino = allocInodeNum(false);
    if (ino == 0) return 0;

    const ts = nowSecs();
    @memset(inobuf[0..inode_size], 0);
    wU16(&inobuf, 0, 0x8000 | (mode & 0x0FFF)); // file type + mode
    wU16(&inobuf, 26, 1);  // nlink=1
    setInoAtime(ts);
    setInoMtime(ts);
    setInoCtime(ts);
    // i_block extent header
    wU16(&inobuf, 40, EXT_MAGIC);
    wU16(&inobuf, 42, 0); // entries=0
    wU16(&inobuf, 44, 4); // max=4
    wU16(&inobuf, 46, 0); // depth=0
    if (!writeInode(ino)) { freeInodeNum(ino, false); return 0; }

    if (!createDirEntry(dir_ino, name, ino, 1)) {
        freeInodeNum(ino, false);
        return 0;
    }
    return ino;
}

/// Create a directory named `name` in `parent_ino`.
/// Returns the new inode number, or 0 on error.
pub fn createDir(parent_ino: u32, name: []const u8, mode: u16) u32 {
    if (!mounted) return 0;
    const ino = allocInodeNum(true);
    if (ino == 0) return 0;

    const ts = nowSecs();
    @memset(inobuf[0..inode_size], 0);
    wU16(&inobuf, 0, 0x4000 | (mode & 0x0FFF)); // dir type + mode
    wU16(&inobuf, 26, 2);  // nlink=2 (. and parent ref)
    setInoAtime(ts);
    setInoMtime(ts);
    setInoCtime(ts);
    wU16(&inobuf, 40, EXT_MAGIC);
    wU16(&inobuf, 42, 0);
    wU16(&inobuf, 44, 4);
    wU16(&inobuf, 46, 0);
    if (!writeInode(ino)) { freeInodeNum(ino, true); return 0; }

    if (!createDirEntry(ino, ".", ino, 2)) { freeInodeNum(ino, true); return 0; }
    if (!createDirEntry(ino, "..", parent_ino, 2)) { freeInodeNum(ino, true); return 0; }

    if (!createDirEntry(parent_ino, name, ino, 2)) {
        freeInodeNum(ino, true);
        return 0;
    }

    if (readInode(parent_ino)) {
        const nl = inoLinks();
        wU16(&inobuf, 26, nl + 1);
        _ = writeInode(parent_ino);
    }
    return ino;
}

/// Unlink (delete) `name` from `dir_ino`.  Frees data blocks and inode when
/// nlink drops to zero.  Returns true on success.
pub fn unlinkFile(dir_ino: u32, name: []const u8) bool {
    if (!mounted) return false;
    const ino = removeDirEntry(dir_ino, name);
    if (ino == 0) return false;

    if (!readInode(ino)) return false;
    const nl = inoLinks();
    if (nl > 1) {
        wU16(&inobuf, 26, nl - 1);
        setInoCtime(nowSecs());
        _ = writeInode(ino);
        return true;
    }

    // nlink → 0: free data blocks (handles depth 0 and 1).
    const is_dir = (inoModeFull() & 0xF000) == 0x4000;
    freeExtentTree();
    @memset(inobuf[0..inode_size], 0);
    _ = writeInode(ino);
    freeInodeNum(ino, is_dir);
    return true;
}

/// Rename (within same parent or across parents) — just moves the dir entry.
pub fn renameEntry(old_dir: u32, old_name: []const u8, new_dir: u32, new_name: []const u8) bool {
    if (!mounted) return false;
    // Peek at child ino and type first.
    if (!readInode(old_dir)) return false;
    const child_ino = lookupName(old_dir, old_name);
    if (child_ino == 0) return false;

    if (!readInode(child_ino)) return false;
    const mode = inoMode();
    const ftype: u8 = if ((mode & 0xF000) == 0x4000) 2 else 1;

    // Remove old entry.
    _ = removeDirEntry(old_dir, old_name);
    // Add new entry.
    return createDirEntry(new_dir, new_name, child_ino, ftype);
}

// ---- read helpers (unchanged from read-only driver) -------------------------

pub const Entry = struct {
    name: [255]u8 = undefined,
    name_len: usize = 0,
    ino: u32 = 0,
    is_dir: bool = false,
};

pub fn entryAt(dir_ino: u32, index: usize) ?Entry {
    if (!mounted or !readInode(dir_ino)) return null;
    if (!isDirMode(inoMode())) return null;
    const size = inoSize();

    var count: usize = 0;
    var lblock: u32 = 0;
    var pos: u32 = 0;
    while (pos < size) : (lblock += 1) {
        const phys = extentLookup(lblock) orelse { pos += block_size; continue; };
        if (!readBlock(phys, blk[0..block_size])) break;
        var off: usize = 0;
        while (off + 8 <= block_size) {
            const ent      = blk[off..];
            const eino     = rU32(ent, 0);
            const rec_len  = rU16(ent, 4);
            if (rec_len < 8) break;
            const name_len = ent[6];
            const ftype    = ent[7];
            if (eino != 0 and name_len != 0) {
                const is_dot = (name_len == 1 and ent[8] == '.') or
                    (name_len == 2 and ent[8] == '.' and ent[9] == '.');
                if (!is_dot) {
                    if (count == index) {
                        var out = Entry{ .ino = eino, .is_dir = (ftype == 2) };
                        out.name_len = @min(@as(usize, name_len), 255);
                        @memcpy(out.name[0..out.name_len], ent[8 .. 8 + out.name_len]);
                        return out;
                    }
                    count += 1;
                }
            }
            off += rec_len;
        }
        pos += block_size;
    }
    return null;
}


/// Change the permission bits of inode `ino`. Updates ctime.
pub fn chmod(ino: u32, mode: u16) bool {
    const irq = irqSave();
    defer irqRestore(irq);
    if (!mounted or !readInode(ino)) return false;
    const file_type = inoModeFull() & 0xF000;
    wU16(&inobuf, 0, file_type | (mode & 0x0FFF));
    setInoCtime(nowSecs());
    return writeInode(ino);
}

/// Return the full mode (type + permission bits) of inode `ino`, or 0 on error.
pub fn getMode(ino: u32) u16 {
    const irq = irqSave();
    defer irqRestore(irq);
    if (!mounted or !readInode(ino)) return 0;
    return inoModeFull();
}

pub fn sizeOf(ino: u32) u32 {
    if (!mounted or !readInode(ino)) return 0;
    return inoSize();
}

pub fn rootIno() u32 { return ROOT_INO; }

pub fn lookupName(dir_ino: u32, name: []const u8) u32 {
    if (!mounted or !readInode(dir_ino)) return 0;
    if (!isDirMode(inoMode())) return 0;
    const size = inoSize();

    var lblock: u32 = 0;
    var pos: u32 = 0;
    while (pos < size) : (lblock += 1) {
        const phys = extentLookup(lblock) orelse { pos += block_size; continue; };
        if (!readBlock(phys, blk[0..block_size])) break;
        var off: usize = 0;
        while (off + 8 <= block_size) {
            const ent      = blk[off..];
            const eino     = rU32(ent, 0);
            const rec_len  = rU16(ent, 4);
            if (rec_len < 8) break;
            const nl = ent[6];
            if (eino != 0 and nl == name.len and
                std.mem.eql(u8, ent[8 .. 8 + nl], name))
                return eino;
            off += rec_len;
        }
        pos += block_size;
    }
    return 0;
}

pub fn resolvePath(path: []const u8) u32 {
    if (!mounted) return 0;
    var ino: u32 = ROOT_INO;
    var it = std.mem.tokenizeScalar(u8, path, '/');
    while (it.next()) |comp| {
        ino = lookupName(ino, comp);
        if (ino == 0) return 0;
    }
    return ino;
}
