//! Kernel heap — a first-fit free-list allocator exposed as std.mem.Allocator.
//!
//! The heap lives in a virtual region starting at 4 GiB (just above the
//! identity-mapped window). It grows on demand by mapping fresh PMM frames with
//! the VMM. Blocks tile the committed region contiguously; each carries a small
//! header so the implicit free list can be walked, split, and coalesced.

const std = @import("std");
const pmm = @import("pmm.zig");
const vmm = @import("vmm.zig");
const console = @import("../arch/x86_64/console.zig");

const PAGE_SIZE: usize = 4096;
const HEAP_BASE: usize = 0x1_0000_0000; // 4 GiB
const GROW_MIN: usize = 64 * 1024; // grow in >=64 KiB chunks

/// Block header. `size` is the whole block (header included) and tiles the heap
/// contiguously; `used` is 0 for free, 1 for allocated.
const Block = extern struct {
    size: usize,
    used: usize,
};

const HDR: usize = @sizeOf(Block); // 16 bytes
const MIN_SPLIT: usize = HDR + 32; // don't split off slivers smaller than this

var heap_top: usize = HEAP_BASE; // end of the committed (mapped) region
var initialized: bool = false;

inline fn alignUp(value: usize, a: usize) usize {
    return (value + a - 1) & ~(a - 1);
}

pub fn init() void {
    heap_top = HEAP_BASE;
    initialized = true;
    console.writeString("[heap] kernel heap ready @ ");
    console.writeHex(HEAP_BASE);
    console.writeString("\n");
}

/// Map fresh frames to extend the committed heap by at least `min_bytes`.
fn grow(min_bytes: usize) bool {
    const grow_size = alignUp(@max(min_bytes, GROW_MIN), PAGE_SIZE);
    const start = heap_top;
    const end = start + grow_size;

    var page = start;
    while (page < end) : (page += PAGE_SIZE) {
        const frame = pmm.alloc() orelse return false;
        if (!vmm.map(page, frame, vmm.WRITABLE)) {
            pmm.free(frame);
            return false;
        }
    }

    const nb: *Block = @ptrFromInt(start);
    nb.size = grow_size;
    nb.used = 0;
    heap_top = end;
    coalesce();
    return true;
}

/// Merge every run of adjacent free blocks.
fn coalesce() void {
    var blk = HEAP_BASE;
    while (blk < heap_top) {
        const b: *Block = @ptrFromInt(blk);
        if (b.used == 0) {
            var next = blk + b.size;
            while (next < heap_top) {
                const nb: *Block = @ptrFromInt(next);
                if (nb.used != 0) break;
                b.size += nb.size;
                next = blk + b.size;
            }
        }
        blk += b.size;
    }
}

fn allocImpl(want: usize, alignment: usize) ?[*]u8 {
    const len = if (want == 0) 1 else want;
    const a = if (alignment < 16) 16 else alignment;

    var blk = HEAP_BASE;
    while (blk < heap_top) {
        const b: *Block = @ptrFromInt(blk);
        if (b.used == 0) {
            // Reserve room for the back-pointer (8 bytes) before the aligned payload.
            const payload = alignUp(blk + HDR + @sizeOf(usize), a);
            const end = payload + len;
            if (end <= blk + b.size) {
                carve(b, blk, payload, end);
                return @ptrFromInt(payload);
            }
        }
        blk += b.size;
    }

    if (!grow(len + alignment + HDR + 64)) return null;
    return allocImpl(want, alignment);
}

fn carve(b: *Block, blk: usize, payload: usize, end: usize) void {
    // Stash the owning block address right before the payload for free().
    @as(*usize, @ptrFromInt(payload - @sizeOf(usize))).* = blk;

    // Split off the tail as a new free block if there is enough room.
    const split = alignUp(end, 16);
    const blk_end = blk + b.size;
    if (blk_end - split >= MIN_SPLIT) {
        const tail: *Block = @ptrFromInt(split);
        tail.size = blk_end - split;
        tail.used = 0;
        b.size = split - blk;
    }
    b.used = 1;
}

fn freeImpl(ptr: [*]u8) void {
    const payload = @intFromPtr(ptr);
    const blk = @as(*usize, @ptrFromInt(payload - @sizeOf(usize))).*;
    const b: *Block = @ptrFromInt(blk);
    b.used = 0;
    coalesce();
}

// ---- std.mem.Allocator glue -------------------------------------------------

fn allocVT(_: *anyopaque, len: usize, alignment: std.mem.Alignment, _: usize) ?[*]u8 {
    return allocImpl(len, alignment.toByteUnits());
}

fn resizeVT(_: *anyopaque, memory: []u8, _: std.mem.Alignment, new_len: usize, _: usize) bool {
    const payload = @intFromPtr(memory.ptr);
    const blk = @as(*usize, @ptrFromInt(payload - @sizeOf(usize))).*;
    const b: *Block = @ptrFromInt(blk);
    const usable = (blk + b.size) - payload;
    return new_len <= usable;
}

fn remapVT(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize, _: usize) ?[*]u8 {
    return null; // force the caller's alloc+copy+free path
}

fn freeVT(_: *anyopaque, memory: []u8, _: std.mem.Alignment, _: usize) void {
    freeImpl(memory.ptr);
}

const vtable = std.mem.Allocator.VTable{
    .alloc = allocVT,
    .resize = resizeVT,
    .remap = remapVT,
    .free = freeVT,
};

/// The kernel allocator. Pass this explicitly to subsystems that need memory.
pub fn allocator() std.mem.Allocator {
    return .{ .ptr = undefined, .vtable = &vtable };
}

/// Bytes currently committed (mapped) to the heap.
pub fn committedBytes() usize {
    return heap_top - HEAP_BASE;
}
