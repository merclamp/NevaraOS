//! Virtual Memory Manager — 4-level paging (x86_64).
//!
//! Operates on the page tables already installed by the boot trampoline (read
//! from CR3). The boot tables identity-map the first 4 GiB using 2 MiB huge
//! pages, so any physical frame the PMM hands out (RAM < 4 GiB) is directly
//! addressable by its physical address. We use that to read/modify page-table
//! frames, and to create fine-grained 4 KiB mappings in the virtual range
//! at or above 4 GiB (where there is no huge-page conflict).

const pmm = @import("pmm.zig");
const console = @import("../arch/x86_64/console.zig");

pub const PAGE_SIZE: usize = 4096;

// Page-table entry flags.
pub const PRESENT: u64 = 1 << 0;
pub const WRITABLE: u64 = 1 << 1;
pub const USER: u64 = 1 << 2;
pub const WRITE_THROUGH: u64 = 1 << 3;
pub const NO_CACHE: u64 = 1 << 4;
pub const HUGE: u64 = 1 << 7;
pub const NO_EXECUTE: u64 = 1 << 63;

/// Physical address bits of a page-table entry.
const ADDR_MASK: u64 = 0x000F_FFFF_FFFF_F000;

extern fn invlpg(virt: u64) void;

inline fn readCr3() usize {
    return asm volatile ("mov %%cr3, %[ret]"
        : [ret] "=r" (-> usize),
    );
}

inline fn tableEntries(table_phys: usize) *[512]u64 {
    // Identity map: physical address is directly usable as a pointer.
    return @ptrFromInt(table_phys);
}

fn index(virt: usize, level: u6) usize {
    return (virt >> (12 + 9 * level)) & 0x1FF;
}

/// Return the child table's physical address for `entry`, creating a fresh
/// zeroed table (from the PMM) if the entry is not present.
fn nextTable(table: *[512]u64, i: usize) ?usize {
    var entry = table[i];
    if (entry & PRESENT == 0) {
        const frame = pmm.alloc() orelse return null;
        const fresh = tableEntries(frame);
        for (fresh) |*e| e.* = 0;
        // USER on intermediate tables is safe: effective access is the AND of
        // all levels, so kernel-only leaves stay kernel-only. It lets user
        // leaves further down be reachable from ring 3.
        entry = frame | PRESENT | WRITABLE | USER;
        table[i] = entry;
    }
    return entry & ADDR_MASK;
}

/// Map a single 4 KiB page `virt` -> `phys` with the given flags.
/// Returns false on out-of-memory while allocating intermediate tables.
pub fn map(virt: usize, phys: usize, flags: u64) bool {
    const pml4 = tableEntries(readCr3() & ADDR_MASK);

    const pdpt_phys = nextTable(pml4, index(virt, 3)) orelse return false;
    const pdpt = tableEntries(pdpt_phys);

    const pd_phys = nextTable(pdpt, index(virt, 2)) orelse return false;
    const pd = tableEntries(pd_phys);

    const pt_phys = nextTable(pd, index(virt, 1)) orelse return false;
    const pt = tableEntries(pt_phys);

    pt[index(virt, 0)] = (phys & ADDR_MASK) | flags | PRESENT;
    invlpg(virt);
    return true;
}

/// Remove a 4 KiB mapping. Does not free intermediate tables.
pub fn unmap(virt: usize) void {
    const phys = walk(virt) orelse return;
    _ = phys;
    const pt = ptOf(virt) orelse return;
    pt[index(virt, 0)] = 0;
    invlpg(virt);
}

/// Return the PT containing `virt`, or null if any level is missing/huge.
fn ptOf(virt: usize) ?*[512]u64 {
    const pml4 = tableEntries(readCr3() & ADDR_MASK);
    const e4 = pml4[index(virt, 3)];
    if (e4 & PRESENT == 0) return null;
    const pdpt = tableEntries(e4 & ADDR_MASK);
    const e3 = pdpt[index(virt, 2)];
    if (e3 & PRESENT == 0 or e3 & HUGE != 0) return null;
    const pd = tableEntries(e3 & ADDR_MASK);
    const e2 = pd[index(virt, 1)];
    if (e2 & PRESENT == 0 or e2 & HUGE != 0) return null;
    return tableEntries(e2 & ADDR_MASK);
}

/// Translate a virtual address to a physical one, honoring 2 MiB huge pages.
pub fn walk(virt: usize) ?usize {
    const pml4 = tableEntries(readCr3() & ADDR_MASK);
    const e4 = pml4[index(virt, 3)];
    if (e4 & PRESENT == 0) return null;
    const pdpt = tableEntries(e4 & ADDR_MASK);
    const e3 = pdpt[index(virt, 2)];
    if (e3 & PRESENT == 0) return null;
    const pd = tableEntries(e3 & ADDR_MASK);
    const e2 = pd[index(virt, 1)];
    if (e2 & PRESENT == 0) return null;
    if (e2 & HUGE != 0) {
        return (e2 & ADDR_MASK) + (virt & 0x1F_FFFF); // 2 MiB offset
    }
    const pt = tableEntries(e2 & ADDR_MASK);
    const e1 = pt[index(virt, 0)];
    if (e1 & PRESENT == 0) return null;
    return (e1 & ADDR_MASK) + (virt & 0xFFF);
}

var kernel_pml4: usize = 0;

pub fn init() void {
    kernel_pml4 = readCr3() & ADDR_MASK;
    console.writeString("[vmm] active (4-level paging, current CR3)\n");
}

pub fn currentCr3() usize {
    return readCr3();
}

pub fn switchTo(pml4_phys: usize) void {
    asm volatile ("mov %[v], %%cr3"
        :
        : [v] "r" (pml4_phys),
        : .{ .memory = true });
}

/// Create a fresh address space that shares the kernel's mappings (the kernel
/// lives in PML4[0], which is copied) but starts empty for user pages. Returns
/// the new PML4 physical address.
pub fn createAddressSpace() ?usize {
    const frame = pmm.alloc() orelse return null;
    const new = tableEntries(frame);
    const kern = tableEntries(kernel_pml4);
    for (0..512) |i| new[i] = kern[i];
    return frame;
}

/// Physical address of the shared kernel address space (PML4 in CR3 at init).
pub fn kernelCr3() usize {
    return kernel_pml4;
}

/// Recursively deep-copy a page-table subtree, allocating fresh frames and
/// copying leaf page contents. `depth` is the number of levels below this table
/// (3 = PDPT, 2 = PD, 1 = PT). Returns the new table's physical address.
fn cloneTable(table_phys: usize, depth: u32) ?usize {
    const new_frame = pmm.alloc() orelse return null;
    const dst = tableEntries(new_frame);
    const src = tableEntries(table_phys);
    for (0..512) |i| {
        const e = src[i];
        if (e & PRESENT == 0) {
            dst[i] = 0;
            continue;
        }
        if (depth == 1) {
            const page = pmm.alloc() orelse return null;
            const s: [*]const u8 = @ptrFromInt(e & ADDR_MASK);
            const d: [*]u8 = @ptrFromInt(page);
            @memcpy(d[0..PAGE_SIZE], s[0..PAGE_SIZE]);
            dst[i] = page | (e & ~ADDR_MASK);
        } else if (e & HUGE != 0) {
            dst[i] = e; // huge page (kernel only; never in user space)
        } else {
            const child = cloneTable(e & ADDR_MASK, depth - 1) orelse return null;
            dst[i] = child | (e & ~ADDR_MASK);
        }
    }
    return new_frame;
}

/// Create a child address space that is a deep copy of `parent_pml4`'s user
/// mappings while sharing the kernel half (PML4[0]). Used by fork().
pub fn forkAddressSpace(parent_pml4: usize) ?usize {
    const new_frame = pmm.alloc() orelse return null;
    const dst = tableEntries(new_frame);
    const par = tableEntries(parent_pml4);
    const kern = tableEntries(kernel_pml4);
    for (0..512) |i| {
        const e = par[i];
        if (i == 0 or (e & PRESENT) == 0) {
            dst[i] = kern[i]; // share the kernel half (and leave empty slots)
        } else {
            const child = cloneTable(e & ADDR_MASK, 3) orelse return null;
            dst[i] = child | (e & ~ADDR_MASK);
        }
    }
    return new_frame;
}

fn freeTable(table_phys: usize, depth: u32) void {
    const tab = tableEntries(table_phys);
    for (0..512) |i| {
        const e = tab[i];
        if (e & PRESENT == 0) continue;
        if (depth == 1) {
            pmm.free(e & ADDR_MASK);
        } else if (e & HUGE == 0) {
            freeTable(e & ADDR_MASK, depth - 1);
        }
    }
    pmm.free(table_phys);
}

/// Free a user address space: its private user page tables and leaf frames, plus
/// the top-level PML4 frame. The shared kernel half (PML4[0]) is left intact.
pub fn freeUserSpace(pml4: usize) void {
    const tab = tableEntries(pml4);
    const kern = tableEntries(kernel_pml4);
    for (1..512) |i| {
        const e = tab[i];
        if (e & PRESENT == 0 or e == kern[i]) continue;
        freeTable(e & ADDR_MASK, 3);
    }
    pmm.free(pml4);
}
