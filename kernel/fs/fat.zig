//! Minimal FAT16 filesystem driver (root directory only).
//!
//! Sits on the ATA block driver. On mount it parses the BPB of an existing FAT16
//! volume, or formats a fresh 16 MiB one if the disk isn't a FAT yet. Supports
//! listing the root directory, reading a file's cluster chain, and creating /
//! overwriting a file in the root. The on-disk format is real FAT16, so the
//! image round-trips with `mkfs.fat` / `fsck.fat` / mtools on the host.

const std = @import("std");
const ata = @import("../arch/x86_64/ata.zig");
const heap = @import("../mm/heap.zig");
const console = @import("../arch/x86_64/console.zig");

const SECTOR: u32 = 512;
const DIR_ENTRY = 32;
const ATTR_ARCHIVE: u8 = 0x20;
const ATTR_VOLUME: u8 = 0x08;
const ATTR_LFN: u8 = 0x0F;
const EOC: u16 = 0xFFF8; // end-of-chain threshold

// Geometry chosen when formatting a fresh disk (16 MiB).
const FMT_TOTAL: u32 = 32768; // sectors
const FMT_SPC: u8 = 1;
const FMT_RESERVED: u16 = 1;
const FMT_NFATS: u8 = 2;
const FMT_ROOT_ENTRIES: u16 = 512;
const FMT_FATSZ: u16 = 128;

var mounted = false;
var spc: u32 = 0;
var reserved: u32 = 0;
var num_fats: u32 = 0;
var root_entries: u32 = 0;
var fat_size: u32 = 0;
var total: u32 = 0;

var fat_start: u32 = 0;
var root_start: u32 = 0;
var data_start: u32 = 0;
var root_dir_sectors: u32 = 0;
var cluster_count: u32 = 0;

var fat_cache: []u8 = &.{};
var sbuf: [SECTOR]u8 = undefined;

inline fn rU16(b: []const u8, off: usize) u16 {
    return std.mem.readInt(u16, b[off..][0..2], .little);
}
inline fn rU32(b: []const u8, off: usize) u32 {
    return std.mem.readInt(u32, b[off..][0..4], .little);
}
inline fn wU16(b: []u8, off: usize, v: u16) void {
    std.mem.writeInt(u16, b[off..][0..2], v, .little);
}
inline fn wU32(b: []u8, off: usize, v: u32) void {
    std.mem.writeInt(u32, b[off..][0..4], v, .little);
}

inline fn clusterBytes() u32 {
    return spc * SECTOR;
}

inline fn clusterLba(cluster: u32) u32 {
    return data_start + (cluster - 2) * spc;
}

fn deriveGeometry() void {
    root_dir_sectors = (root_entries * DIR_ENTRY + SECTOR - 1) / SECTOR;
    fat_start = reserved;
    root_start = reserved + num_fats * fat_size;
    data_start = root_start + root_dir_sectors;
    cluster_count = (total - data_start) / spc;
}

fn loadFat() bool {
    const a = heap.allocator();
    const bytes = fat_size * SECTOR;
    fat_cache = a.alloc(u8, bytes) catch return false;
    var i: u32 = 0;
    while (i < fat_size) : (i += 1) {
        if (!ata.readSector(fat_start + i, &sbuf)) return false;
        @memcpy(fat_cache[i * SECTOR ..][0..SECTOR], sbuf[0..SECTOR]);
    }
    return true;
}

fn flushFat() void {
    var f: u32 = 0;
    while (f < num_fats) : (f += 1) {
        var i: u32 = 0;
        while (i < fat_size) : (i += 1) {
            @memcpy(sbuf[0..SECTOR], fat_cache[i * SECTOR ..][0..SECTOR]);
            _ = ata.writeSector(fat_start + f * fat_size + i, &sbuf);
        }
    }
}

inline fn fatGet(cluster: u32) u16 {
    return rU16(fat_cache, cluster * 2);
}
inline fn fatSet(cluster: u32, v: u16) void {
    wU16(fat_cache, cluster * 2, v);
}

fn allocCluster() u32 {
    var c: u32 = 2;
    while (c < cluster_count + 2) : (c += 1) {
        if (fatGet(c) == 0) {
            fatSet(c, 0xFFFF);
            return c;
        }
    }
    return 0;
}

fn freeChain(first: u16) void {
    var c: u32 = first;
    while (c >= 2 and c < EOC) {
        const next = fatGet(c);
        fatSet(c, 0);
        c = next;
    }
}

/// Mount the disk: parse an existing FAT16 BPB, or format a fresh one.
pub fn mount() bool {
    if (!ata.isPresent()) return false;
    if (!ata.readSector(0, &sbuf)) return false;

    const valid = sbuf[510] == 0x55 and sbuf[511] == 0xAA and
        rU16(&sbuf, 11) == SECTOR and sbuf[13] != 0 and sbuf[16] != 0;

    if (valid) {
        spc = sbuf[13];
        reserved = rU16(&sbuf, 14);
        num_fats = sbuf[16];
        root_entries = rU16(&sbuf, 17);
        const t16 = rU16(&sbuf, 19);
        fat_size = rU16(&sbuf, 22);
        total = if (t16 != 0) t16 else rU32(&sbuf, 32);
        deriveGeometry();
        console.writeString("[fat] mounted existing FAT16\n");
    } else {
        if (!format()) return false;
        console.writeString("[fat] formatted fresh FAT16\n");
    }

    if (!loadFat()) return false;
    mounted = true;
    return true;
}

fn format() bool {
    spc = FMT_SPC;
    reserved = FMT_RESERVED;
    num_fats = FMT_NFATS;
    root_entries = FMT_ROOT_ENTRIES;
    fat_size = FMT_FATSZ;
    total = FMT_TOTAL;
    deriveGeometry();

    // Boot sector + BPB.
    @memset(sbuf[0..SECTOR], 0);
    sbuf[0] = 0xEB;
    sbuf[1] = 0x3C;
    sbuf[2] = 0x90;
    @memcpy(sbuf[3..11], "NEVARAOS");
    wU16(&sbuf, 11, SECTOR);
    sbuf[13] = @intCast(spc);
    wU16(&sbuf, 14, @intCast(reserved));
    sbuf[16] = @intCast(num_fats);
    wU16(&sbuf, 17, @intCast(root_entries));
    wU16(&sbuf, 19, @intCast(total));
    sbuf[21] = 0xF8; // media: fixed disk
    wU16(&sbuf, 22, @intCast(fat_size));
    wU16(&sbuf, 24, 63); // sectors per track
    wU16(&sbuf, 26, 16); // heads
    wU32(&sbuf, 28, 0); // hidden sectors
    wU32(&sbuf, 32, 0); // total_sectors_32 (using 16-bit field)
    sbuf[36] = 0x80; // drive number
    sbuf[38] = 0x29; // extended boot signature
    wU32(&sbuf, 39, 0x4E455641); // volume id
    @memcpy(sbuf[43..54], "NEVARA     ");
    @memcpy(sbuf[54..62], "FAT16   ");
    sbuf[510] = 0x55;
    sbuf[511] = 0xAA;
    if (!ata.writeSector(0, &sbuf)) return false;

    // Zero the FAT and root-directory regions.
    @memset(sbuf[0..SECTOR], 0);
    var s: u32 = 1;
    while (s < data_start) : (s += 1) {
        if (!ata.writeSector(s, &sbuf)) return false;
    }

    // Seed the two reserved FAT entries in both FAT copies.
    @memset(sbuf[0..SECTOR], 0);
    wU16(&sbuf, 0, 0xFFF8); // entry 0: media
    wU16(&sbuf, 2, 0xFFFF); // entry 1: end-of-chain
    var f: u32 = 0;
    while (f < num_fats) : (f += 1) {
        if (!ata.writeSector(fat_start + f * fat_size, &sbuf)) return false;
    }

    // Volume label as the first root-directory entry (keeps fsck happy).
    @memset(sbuf[0..SECTOR], 0);
    @memcpy(sbuf[0..11], "NEVARA     ");
    sbuf[11] = ATTR_VOLUME;
    if (!ata.writeSector(root_start, &sbuf)) return false;
    return true;
}

// ---- 8.3 name conversion ---------------------------------------------------

/// Encode "hello.txt" into the 11-byte padded FAT short name "HELLO   TXT".
fn encode83(name: []const u8, out: *[11]u8) void {
    @memset(out, ' ');
    var i: usize = 0;
    var o: usize = 0;
    // base (up to 8)
    while (i < name.len and name[i] != '.' and o < 8) : (i += 1) {
        out[o] = upper(name[i]);
        o += 1;
    }
    // skip to extension
    while (i < name.len and name[i] != '.') i += 1;
    if (i < name.len and name[i] == '.') i += 1;
    o = 8;
    while (i < name.len and o < 11) : (i += 1) {
        out[o] = upper(name[i]);
        o += 1;
    }
}

/// Decode a padded 11-byte short name into "hello.txt" (lowercase). Returns the
/// length written to `out`.
fn decode83(raw: []const u8, out: []u8) usize {
    var n: usize = 0;
    var base: usize = 8;
    while (base > 0 and raw[base - 1] == ' ') base -= 1;
    var i: usize = 0;
    while (i < base) : (i += 1) {
        out[n] = lower(raw[i]);
        n += 1;
    }
    var ext: usize = 11;
    while (ext > 8 and raw[ext - 1] == ' ') ext -= 1;
    if (ext > 8) {
        out[n] = '.';
        n += 1;
        i = 8;
        while (i < ext) : (i += 1) {
            out[n] = lower(raw[i]);
            n += 1;
        }
    }
    return n;
}

inline fn upper(c: u8) u8 {
    return if (c >= 'a' and c <= 'z') c - 32 else c;
}
inline fn lower(c: u8) u8 {
    return if (c >= 'A' and c <= 'Z') c + 32 else c;
}

// ---- Root directory iteration ----------------------------------------------

/// Call `cb` for each regular file in the root directory.
pub fn forEachRoot(ctx: anytype, comptime cb: fn (@TypeOf(ctx), name: []const u8, cluster: u16, size: u32) void) void {
    if (!mounted) return;
    var s: u32 = 0;
    while (s < root_dir_sectors) : (s += 1) {
        if (!ata.readSector(root_start + s, &sbuf)) return;
        var e: usize = 0;
        while (e < SECTOR) : (e += DIR_ENTRY) {
            const ent = sbuf[e .. e + DIR_ENTRY];
            if (ent[0] == 0x00) return; // no more entries
            if (ent[0] == 0xE5) continue; // deleted
            const attr = ent[11];
            if (attr & ATTR_VOLUME != 0 or attr == ATTR_LFN) continue;
            var namebuf: [13]u8 = undefined;
            const n = decode83(ent[0..11], &namebuf);
            cb(ctx, namebuf[0..n], rU16(ent, 26), rU32(ent, 28));
        }
    }
}

/// Read a file's cluster chain into `out`. Returns bytes read.
pub fn readFile(first_cluster: u16, size: u32, out: []u8) usize {
    if (!mounted) return 0;
    var done: usize = 0;
    var c: u32 = first_cluster;
    const cb = clusterBytes();
    while (c >= 2 and c < EOC and done < size) {
        var k: u32 = 0;
        while (k < spc and done < size) : (k += 1) {
            if (!ata.readSector(clusterLba(c) + k, &sbuf)) return done;
            const want = @min(@as(usize, SECTOR), size - done);
            const room = @min(want, out.len - done);
            @memcpy(out[done..][0..room], sbuf[0..room]);
            done += room;
            if (done >= out.len) return done;
        }
        _ = cb;
        c = fatGet(c);
    }
    return done;
}

/// Create or overwrite a root-directory file with `data`. Returns false on
/// failure (no space, name too long, disk error).
pub fn writeFile(name: []const u8, data: []const u8) bool {
    if (!mounted) return false;
    var short: [11]u8 = undefined;
    encode83(name, &short);

    // Find an existing entry (to overwrite) or a free slot.
    var slot_sector: u32 = 0;
    var slot_off: usize = 0;
    var found = false;
    var free_sector: u32 = 0;
    var free_off: usize = 0;
    var has_free = false;

    var s: u32 = 0;
    scan: while (s < root_dir_sectors) : (s += 1) {
        if (!ata.readSector(root_start + s, &sbuf)) return false;
        var e: usize = 0;
        while (e < SECTOR) : (e += DIR_ENTRY) {
            const ent = sbuf[e .. e + DIR_ENTRY];
            if (ent[0] == 0x00 or ent[0] == 0xE5) {
                if (!has_free) {
                    free_sector = root_start + s;
                    free_off = e;
                    has_free = true;
                }
                if (ent[0] == 0x00) break :scan;
                continue;
            }
            if (std.mem.eql(u8, ent[0..11], &short)) {
                slot_sector = root_start + s;
                slot_off = e;
                found = true;
                // Free its old cluster chain before rewriting.
                freeChain(rU16(ent, 26));
                break :scan;
            }
        }
    }

    if (!found) {
        if (!has_free) return false;
        slot_sector = free_sector;
        slot_off = free_off;
    }

    // Allocate a cluster chain and write the data.
    var first: u16 = 0;
    if (data.len > 0) {
        const cb = clusterBytes();
        const need = (data.len + cb - 1) / cb;
        var prev: u32 = 0;
        var written: usize = 0;
        var n: usize = 0;
        while (n < need) : (n += 1) {
            const c = allocCluster();
            if (c == 0) return false;
            if (prev == 0) first = @intCast(c) else fatSet(prev, @intCast(c));
            prev = c;
            // Write this cluster's sectors.
            var k: u32 = 0;
            while (k < spc) : (k += 1) {
                @memset(sbuf[0..SECTOR], 0);
                const chunk = @min(@as(usize, SECTOR), data.len - written);
                if (chunk > 0) @memcpy(sbuf[0..chunk], data[written..][0..chunk]);
                if (!ata.writeSector(clusterLba(c) + k, &sbuf)) return false;
                written += chunk;
                if (written >= data.len) break;
            }
        }
        fatSet(prev, 0xFFFF);
    }
    flushFat();

    // Write the directory entry.
    if (!ata.readSector(slot_sector, &sbuf)) return false;
    const ent = sbuf[slot_off .. slot_off + DIR_ENTRY];
    @memset(ent, 0);
    @memcpy(ent[0..11], &short);
    ent[11] = ATTR_ARCHIVE;
    wU16(ent, 26, first);
    wU32(ent, 28, @intCast(data.len));
    return ata.writeSector(slot_sector, &sbuf);
}
