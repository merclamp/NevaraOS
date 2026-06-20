//! Read-only ext4 driver (extent-based files, linear directories).
//!
//! Reads a real ext4 volume on the ATA primary slave: superblock, block-group
//! descriptors, inodes, extent trees, and directory entries. It targets the
//! common case produced by `mke2fs -t ext4` (extents, filetype) and skips the
//! write-side machinery (block/inode bitmaps, the journal, metadata checksums),
//! so it is mounted read-only. Block sizes 1024/2048/4096 are supported.

const std = @import("std");
const ata = @import("../arch/x86_64/ata.zig");
const console = @import("../arch/x86_64/console.zig");

const DRIVE: u1 = 1; // primary slave
const SECTOR: u32 = 512;
const SB_OFFSET: u32 = 1024;
const EXT4_MAGIC: u16 = 0xEF53;
const EXT_MAGIC: u16 = 0xF30A;
const ROOT_INO: u32 = 2;
const MAX_BLOCK: usize = 4096;

var mounted = false;
var block_size: u32 = 0;
var inodes_per_group: u32 = 0;
var inode_size: u32 = 0;
var first_data_block: u32 = 0;
var desc_size: u32 = 32;

var blk: [MAX_BLOCK]u8 = undefined;
var inobuf: [256]u8 = undefined;

inline fn rU16(b: []const u8, o: usize) u16 {
    return std.mem.readInt(u16, b[o..][0..2], .little);
}
inline fn rU32(b: []const u8, o: usize) u32 {
    return std.mem.readInt(u32, b[o..][0..4], .little);
}

/// Read a filesystem block into `out` (block_size bytes).
fn readBlock(block: u32, out: []u8) bool {
    const spb = block_size / SECTOR;
    var k: u32 = 0;
    while (k < spb) : (k += 1) {
        var sec: [SECTOR]u8 = undefined;
        if (!ata.readSectorOn(DRIVE, block * spb + k, &sec)) return false;
        @memcpy(out[k * SECTOR ..][0..SECTOR], sec[0..SECTOR]);
    }
    return true;
}

pub fn mount() bool {
    if (!ata.isPresentOn(DRIVE)) return false;

    // The superblock lives 1024 bytes in (sectors 2 and 3).
    var sb: [1024]u8 = undefined;
    var s0: [SECTOR]u8 = undefined;
    var s1: [SECTOR]u8 = undefined;
    if (!ata.readSectorOn(DRIVE, SB_OFFSET / SECTOR, &s0)) return false;
    if (!ata.readSectorOn(DRIVE, SB_OFFSET / SECTOR + 1, &s1)) return false;
    @memcpy(sb[0..SECTOR], s0[0..SECTOR]);
    @memcpy(sb[SECTOR..1024], s1[0..SECTOR]);

    if (rU16(&sb, 56) != EXT4_MAGIC) return false;

    const log_bs = rU32(&sb, 24);
    block_size = @as(u32, 1024) << @intCast(log_bs);
    if (block_size > MAX_BLOCK) return false;
    inodes_per_group = rU32(&sb, 40);
    inode_size = rU16(&sb, 88);
    if (inode_size == 0) inode_size = 128;
    first_data_block = rU32(&sb, 20);
    const incompat = rU32(&sb, 96);
    if (incompat & 0x80 != 0) desc_size = rU16(&sb, 254) else desc_size = 32; // 64BIT
    if (desc_size == 0) desc_size = 32;

    mounted = true;
    console.writeString("[ext4] mounted read-only\n");
    return true;
}

/// Load inode `ino` into `inobuf`. Returns false on error.
fn readInode(ino: u32) bool {
    const group = (ino - 1) / inodes_per_group;
    const index = (ino - 1) % inodes_per_group;

    // Block group descriptor table starts in the block after the superblock.
    const gdt_block = first_data_block + 1;
    const desc_byte = group * desc_size;
    const desc_blk = gdt_block + desc_byte / block_size;
    const desc_off = desc_byte % block_size;
    if (!readBlock(desc_blk, blk[0..block_size])) return false;
    const inode_table = rU32(blk[0..block_size], desc_off + 8); // bg_inode_table_lo

    const inode_byte = index * inode_size;
    const itbl_blk = inode_table + inode_byte / block_size;
    const itbl_off = inode_byte % block_size;
    if (!readBlock(itbl_blk, blk[0..block_size])) return false;
    @memcpy(inobuf[0..256], blk[itbl_off..][0..256]);
    return true;
}

inline fn inoMode() u16 {
    return rU16(&inobuf, 0);
}
inline fn inoSize() u32 {
    return rU32(&inobuf, 4); // i_size_lo (files < 4 GiB)
}
pub fn isDirMode(mode: u16) bool {
    return (mode & 0xF000) == 0x4000;
}

/// Resolve a file's logical block to a physical block via the extent tree.
/// Handles in-inode extents at depth 0 and one level of extent index.
fn extentLookup(logical: u32) ?u32 {
    // i_block (60 bytes at offset 40) starts with the extent header.
    if (rU16(&inobuf, 40) != EXT_MAGIC) return null;
    return extentSearch(inobuf[40 .. 40 + 60], logical, 0);
}

var extblk: [MAX_BLOCK]u8 = undefined;

fn extentSearch(node: []const u8, logical: u32, level: u32) ?u32 {
    const entries = rU16(node, 2);
    const depth = rU16(node, 6);
    var i: usize = 0;
    if (depth == 0) {
        while (i < entries) : (i += 1) {
            const e = node[12 + i * 12 ..];
            const ee_block = rU32(e, 0);
            const ee_len = rU16(e, 4) & 0x7FFF;
            const ee_start = rU32(e, 8);
            if (logical >= ee_block and logical < ee_block + ee_len) {
                return ee_start + (logical - ee_block);
            }
        }
        return null;
    }
    // Index node: pick the last child whose ei_block <= logical.
    if (level > 2) return null;
    var chosen: u32 = 0;
    var found = false;
    while (i < entries) : (i += 1) {
        const e = node[12 + i * 12 ..];
        const ei_block = rU32(e, 0);
        if (ei_block <= logical) {
            chosen = rU32(e, 4); // ei_leaf_lo
            found = true;
        }
    }
    if (!found) return null;
    if (!readBlock(chosen, extblk[0..block_size])) return null;
    if (rU16(&extblk, 0) != EXT_MAGIC) return null;
    return extentSearch(extblk[0..block_size], logical, level + 1);
}

/// Read a regular file's contents into `out`. Returns bytes read.
pub fn readFile(ino: u32, out: []u8) usize {
    if (!mounted or !readInode(ino)) return 0;
    const size = @min(@as(usize, inoSize()), out.len);
    var done: usize = 0;
    var lblock: u32 = 0;
    while (done < size) : (lblock += 1) {
        const phys = extentLookup(lblock) orelse break;
        if (!readBlock(phys, blk[0..block_size])) break;
        const chunk = @min(@as(usize, block_size), size - done);
        @memcpy(out[done..][0..chunk], blk[0..chunk]);
        done += chunk;
    }
    return done;
}

pub const Entry = struct {
    name: [255]u8 = undefined,
    name_len: usize = 0,
    ino: u32 = 0,
    is_dir: bool = false,
};

/// Return the `index`-th child of directory inode `dir_ino` (skipping "." and
/// "..", and entries the reader can't represent). Linear directory blocks only.
pub fn entryAt(dir_ino: u32, index: usize) ?Entry {
    if (!mounted or !readInode(dir_ino)) return null;
    if (!isDirMode(inoMode())) return null;
    const size = inoSize();

    var count: usize = 0;
    var lblock: u32 = 0;
    var pos: u32 = 0;
    while (pos < size) : (lblock += 1) {
        const phys = extentLookup(lblock) orelse break;
        if (!readBlock(phys, blk[0..block_size])) break;
        var off: usize = 0;
        while (off + 8 <= block_size) {
            const ent = blk[off..];
            const eino = rU32(ent, 0);
            const rec_len = rU16(ent, 4);
            if (rec_len < 8) break;
            const name_len = ent[6];
            const ftype = ent[7];
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

/// Size (in bytes) of inode `ino`.
pub fn sizeOf(ino: u32) u32 {
    if (!mounted or !readInode(ino)) return 0;
    return inoSize();
}
