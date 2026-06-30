//! Physical Memory Manager — bitmap frame allocator.
//!
//! Manages physical RAM in 4 KiB frames. One bit per frame: 1 = used, 0 = free.
//! The bitmap is built from the Multiboot2 memory map and placed in RAM just
//! after the kernel image (and the boot-info structure). This is the simple
//! first-stage allocator; a buddy allocator can layer on top later.

const console = @import("../arch/x86_64/console.zig");
const mb2 = @import("../arch/x86_64/multiboot2.zig");

pub const PAGE_SIZE: usize = 4096;

/// End of the loaded kernel image (from the linker script).
extern const kernel_end: u8;

var bitmap: [*]u8 = undefined;
var bitmap_len: usize = 0; // bytes
var total_frames: usize = 0;
var used_frames: usize = 0;
var next_hint: usize = 0;

// Per-frame reference count for shared frames (copy-on-write). The value is the
// number of *extra* owners beyond the first, so a freshly allocated frame has
// refcount 0 (one owner) and existing free() callers need no change: free()
// only releases the frame to the bitmap once the last extra reference is gone.
var refcount: [*]u16 = undefined;
var refcount_len: usize = 0; // bytes

inline fn alignUp(value: usize, a: usize) usize {
    return (value + a - 1) & ~(a - 1);
}

inline fn alignDown(value: usize, a: usize) usize {
    return value & ~(a - 1);
}

fn markUsed(frame: usize) void {
    if (frame >= total_frames) return;
    const byte = frame >> 3;
    const bit = @as(u8, 1) << @as(u3, @intCast(frame & 7));
    if (bitmap[byte] & bit == 0) {
        bitmap[byte] |= bit;
        used_frames += 1;
    }
}

fn markFree(frame: usize) void {
    if (frame >= total_frames) return;
    const byte = frame >> 3;
    const bit = @as(u8, 1) << @as(u3, @intCast(frame & 7));
    if (bitmap[byte] & bit != 0) {
        bitmap[byte] &= ~bit;
        used_frames -= 1;
    }
}

fn testFrame(frame: usize) bool {
    const byte = frame >> 3;
    const bit = @as(u8, 1) << @as(u3, @intCast(frame & 7));
    return bitmap[byte] & bit != 0;
}

/// Reserve every frame overlapping [start, end).
fn reserveRange(start: usize, end: usize) void {
    var f = alignDown(start, PAGE_SIZE) / PAGE_SIZE;
    const last = alignUp(end, PAGE_SIZE) / PAGE_SIZE;
    while (f < last) : (f += 1) markUsed(f);
}

/// Initialize the PMM from the Multiboot2 boot information.
pub fn init(info_addr: usize) void {
    // 1. Find the highest available physical address.
    var highest: u64 = 0;
    var it = mb2.memoryMap(info_addr) orelse {
        console.writeString("[pmm] PANIC: no memory map from bootloader\n");
        while (true) asm volatile ("cli; hlt");
    };
    while (it.next()) |r| {
        if (r.available) {
            const top = r.base + r.length;
            if (top > highest) highest = top;
        }
    }

    total_frames = @intCast(highest / PAGE_SIZE);

    // 2. Place the bitmap after both the kernel image and the boot info.
    const kend = @intFromPtr(&kernel_end);
    const info_end = info_addr + mb2.infoSize(info_addr);
    const bitmap_start = alignUp(@max(kend, info_end), PAGE_SIZE);
    bitmap = @ptrFromInt(bitmap_start);
    bitmap_len = alignUp((total_frames + 7) / 8, PAGE_SIZE);

    // The refcount table lives immediately after the bitmap.
    const refcount_start = bitmap_start + bitmap_len;
    refcount = @ptrFromInt(refcount_start);
    refcount_len = alignUp(total_frames * @sizeOf(u16), PAGE_SIZE);

    // 3. Everything used by default; refcounts start at zero.
    var i: usize = 0;
    while (i < bitmap_len) : (i += 1) bitmap[i] = 0xFF;
    used_frames = total_frames;
    i = 0;
    while (i < total_frames) : (i += 1) refcount[i] = 0;

    // 4. Free the available regions reported by the bootloader.
    it = mb2.memoryMap(info_addr).?;
    while (it.next()) |r| {
        if (!r.available) continue;
        var f = alignUp(@intCast(r.base), PAGE_SIZE) / PAGE_SIZE;
        const end_f = (@as(usize, @intCast(r.base + r.length))) / PAGE_SIZE;
        while (f < end_f) : (f += 1) markFree(f);
    }

    // 5. Reserve the regions we must never hand out.
    reserveRange(0, 0x100000); // low 1 MiB (BIOS/IVT/EBDA)
    reserveRange(0x100000, kend); // the kernel image
    reserveRange(bitmap_start, bitmap_start + bitmap_len); // the bitmap itself
    reserveRange(refcount_start, refcount_start + refcount_len); // the refcount table
    reserveRange(info_addr, info_end); // the Multiboot2 info

    // Reserve any GRUB-loaded module (the ext4 rootfs ramdisk). Its file data is
    // read lazily long after boot, so these frames must never be handed out.
    if (mb2.findModule(info_addr)) |mod| {
        reserveRange(mod.start, mod.end);
    }

    next_hint = 0;

    console.writeString("[pmm] frames: ");
    console.writeDec(total_frames);
    console.writeString(" total, ");
    console.writeDec(total_frames - used_frames);
    console.writeString(" free (");
    console.writeDec((total_frames - used_frames) * PAGE_SIZE / (1024 * 1024));
    console.writeString(" MiB), bitmap @ ");
    console.writeHex(bitmap_start);
    console.writeString("\n");
}

/// Allocate one physical frame. Returns its physical address, or null if OOM.
pub fn alloc() ?usize {
    var scanned: usize = 0;
    var f = next_hint;
    while (scanned < total_frames) : (scanned += 1) {
        if (f >= total_frames) f = 0;
        if (!testFrame(f)) {
            markUsed(f);
            refcount[f] = 0;
            next_hint = f + 1;
            return f * PAGE_SIZE;
        }
        f += 1;
    }
    return null;
}

/// Free a previously allocated physical frame. If the frame is shared (extra
/// references exist from copy-on-write), this just drops one reference and the
/// frame stays allocated for the remaining owners.
pub fn free(phys: usize) void {
    const frame = phys / PAGE_SIZE;
    if (frame >= total_frames) return;
    if (refcount[frame] > 0) {
        refcount[frame] -= 1;
        return;
    }
    markFree(frame);
    if (frame < next_hint) next_hint = frame;
}

/// Add a reference to a frame so it survives the next free() (copy-on-write
/// sharing between a forked parent and child).
pub fn incRef(phys: usize) void {
    const frame = phys / PAGE_SIZE;
    if (frame < total_frames) refcount[frame] += 1;
}

/// Number of *extra* references on a frame (0 means a single owner).
pub fn refCount(phys: usize) u16 {
    const frame = phys / PAGE_SIZE;
    return if (frame < total_frames) refcount[frame] else 0;
}

/// Allocate `n_pages` contiguous physical frames all below 4 GiB (DMA-safe).
/// The frames are identity-mapped (phys == virt) so the returned address can
/// be passed directly to 32-bit PCI DMA registers.
/// Returns the base physical/virtual address, or null if OOM.
pub fn allocLow32(n_pages: usize) ?usize {
    const MAX_FRAME_4G: usize = 0x1_0000_0000 / PAGE_SIZE; // 1 M frames
    const limit = @min(total_frames, MAX_FRAME_4G);
    var f: usize = 0x100; // start after low 1 MiB
    while (f + n_pages <= limit) : (f += 1) {
        // Check that all n_pages frames starting at f are free.
        var ok = true;
        var k: usize = 0;
        while (k < n_pages) : (k += 1) {
            if (testFrame(f + k)) { ok = false; break; }
        }
        if (!ok) continue;
        // Mark them all used.
        k = 0;
        while (k < n_pages) : (k += 1) markUsed(f + k);
        return f * PAGE_SIZE;
    }
    return null;
}

/// Free `n_pages` contiguous frames starting at physical address `phys`.
pub fn freePages(phys: usize, n_pages: usize) void {
    const base = phys / PAGE_SIZE;
    var k: usize = 0;
    while (k < n_pages) : (k += 1) markFree(base + k);
}

pub fn freeFrames() usize {
    return total_frames - used_frames;
}

pub fn totalFrames() usize {
    return total_frames;
}
