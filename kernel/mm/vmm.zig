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
        entry = frame | PRESENT | WRITABLE;
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

pub fn init() void {
    console.writeString("[vmm] active (4-level paging, current CR3)\n");
}
