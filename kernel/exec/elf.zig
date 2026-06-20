//! Minimal ELF64 loader for static (ET_EXEC) x86_64 user programs.
//!
//! Maps each PT_LOAD segment at its virtual address as user pages, copies the
//! file contents, and zeroes the rest (bss). Returns the entry point.

const std = @import("std");
const pmm = @import("../mm/pmm.zig");
const vmm = @import("../mm/vmm.zig");

const PT_LOAD: u32 = 1;
const ET_EXEC: u16 = 2;
const EM_X86_64: u16 = 0x3E;
const PAGE: usize = 4096;

const Elf64_Ehdr = extern struct {
    e_ident: [16]u8,
    e_type: u16,
    e_machine: u16,
    e_version: u32,
    e_entry: u64,
    e_phoff: u64,
    e_shoff: u64,
    e_flags: u32,
    e_ehsize: u16,
    e_phentsize: u16,
    e_phnum: u16,
    e_shentsize: u16,
    e_shnum: u16,
    e_shstrndx: u16,
};

const Elf64_Phdr = extern struct {
    p_type: u32,
    p_flags: u32,
    p_offset: u64,
    p_vaddr: u64,
    p_paddr: u64,
    p_filesz: u64,
    p_memsz: u64,
    p_align: u64,
};

inline fn alignDown(v: usize, a: usize) usize {
    return v & ~(a - 1);
}

/// Load a static ELF image. Returns the entry virtual address, or null if the
/// image is not a valid x86_64 ET_EXEC.
pub fn load(image: []const u8) ?usize {
    if (image.len < @sizeOf(Elf64_Ehdr)) return null;

    var eh: Elf64_Ehdr = undefined;
    @memcpy(std.mem.asBytes(&eh), image[0..@sizeOf(Elf64_Ehdr)]);

    if (!(eh.e_ident[0] == 0x7F and eh.e_ident[1] == 'E' and
        eh.e_ident[2] == 'L' and eh.e_ident[3] == 'F')) return null;
    if (eh.e_ident[4] != 2) return null; // ELFCLASS64
    if (eh.e_type != ET_EXEC) return null;
    if (eh.e_machine != EM_X86_64) return null;

    var i: usize = 0;
    while (i < eh.e_phnum) : (i += 1) {
        const off = eh.e_phoff + i * eh.e_phentsize;
        if (off + @sizeOf(Elf64_Phdr) > image.len) return null;
        var ph: Elf64_Phdr = undefined;
        @memcpy(std.mem.asBytes(&ph), image[off .. off + @sizeOf(Elf64_Phdr)]);
        if (ph.p_type != PT_LOAD) continue;
        if (!mapSegment(image, ph)) return null;
    }

    return eh.e_entry;
}

fn mapSegment(image: []const u8, ph: Elf64_Phdr) bool {
    const flags = vmm.PRESENT | vmm.WRITABLE | vmm.USER;

    // Map (and zero) every page the segment spans.
    var va = alignDown(@intCast(ph.p_vaddr), PAGE);
    const end: usize = @intCast(ph.p_vaddr + ph.p_memsz);
    while (va < end) : (va += PAGE) {
        if (vmm.walk(va) == null) {
            const frame = pmm.alloc() orelse return false;
            if (!vmm.map(va, frame, flags)) return false;
            const page: [*]u8 = @ptrFromInt(va);
            @memset(page[0..PAGE], 0);
        }
    }

    // Copy the file-backed portion; the remainder stays zero (bss).
    const dst: [*]u8 = @ptrFromInt(@as(usize, @intCast(ph.p_vaddr)));
    const fsz: usize = @intCast(ph.p_filesz);
    const foff: usize = @intCast(ph.p_offset);
    @memcpy(dst[0..fsz], image[foff .. foff + fsz]);
    // Zero the bss tail explicitly so reloading into an already-mapped address
    // space starts with a clean .bss.
    const msz: usize = @intCast(ph.p_memsz);
    if (msz > fsz) @memset(dst[fsz..msz], 0);
    return true;
}
