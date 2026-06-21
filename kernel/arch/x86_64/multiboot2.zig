//! Multiboot2 boot information parser.
//!
//! GRUB hands the kernel a pointer to a boot-information structure (in ebx,
//! forwarded as `kmain`'s `info` argument). It begins with a 32-bit total size
//! and a reserved word, followed by a list of 8-byte-aligned tags. We walk the
//! tags to extract the physical memory map.

const console = @import("console.zig");
const fb = @import("fb.zig");

const TAG_END: u32 = 0;
const TAG_MODULE: u32 = 3;
const TAG_MMAP: u32 = 6;
const TAG_FRAMEBUFFER: u32 = 8;

/// Multiboot2 module tag (type 3).
const ModuleTag = extern struct {
    type: u32,
    size: u32,
    mod_start: u32, // physical address of module start
    mod_end:   u32, // physical address of module end (exclusive)
    // null-terminated command string follows
};

/// A loaded module (e.g. rootfs.ext4).
pub const Module = struct {
    start: u32,
    end:   u32,
};

/// Common header at the start of every tag.
const TagHeader = extern struct {
    type: u32,
    size: u32,
};

/// Memory map tag (type 6) header; entries follow immediately after.
const MmapTag = extern struct {
    type: u32,
    size: u32,
    entry_size: u32,
    entry_version: u32,
};

/// Framebuffer info tag (type 8). Color-format fields follow but are unused.
const FramebufferTag = extern struct {
    type: u32,
    size: u32,
    addr: u64,
    pitch: u32,
    width: u32,
    height: u32,
    bpp: u8,
    fb_type: u8,
    reserved: u8,
};

/// One memory map entry.
const MmapEntry = extern struct {
    base_addr: u64,
    length: u64,
    type: u32,
    reserved: u32,
};

// Memory region types as defined by the Multiboot2 spec.
const MEM_AVAILABLE: u32 = 1;
const MEM_RESERVED: u32 = 2;
const MEM_ACPI_RECLAIMABLE: u32 = 3;
const MEM_NVS: u32 = 4;
const MEM_BADRAM: u32 = 5;

fn typeName(t: u32) []const u8 {
    return switch (t) {
        MEM_AVAILABLE => "available",
        MEM_RESERVED => "reserved",
        MEM_ACPI_RECLAIMABLE => "ACPI reclaimable",
        MEM_NVS => "ACPI NVS",
        MEM_BADRAM => "bad RAM",
        else => "unknown",
    };
}

fn alignUp8(value: usize) usize {
    return (value + 7) & ~@as(usize, 7);
}

/// A single physical memory region surfaced to the rest of the kernel.
pub const Region = struct {
    base: u64,
    length: u64,
    available: bool,
};

/// Iterator over the Multiboot2 memory map entries.
pub const MemoryMap = struct {
    cursor: usize,
    end: usize,
    entry_size: usize,

    pub fn next(self: *MemoryMap) ?Region {
        if (self.cursor + @sizeOf(MmapEntry) > self.end) return null;
        const e: *const MmapEntry = @ptrFromInt(self.cursor);
        self.cursor += self.entry_size;
        return .{
            .base = e.base_addr,
            .length = e.length,
            .available = e.type == MEM_AVAILABLE,
        };
    }
};

/// Return an iterator over the physical memory map, or null if absent.
pub fn memoryMap(info_addr: usize) ?MemoryMap {
    const total_size: u32 = @as(*const u32, @ptrFromInt(info_addr)).*;
    var offset: usize = 8;
    while (offset < total_size) {
        const tag: *const TagHeader = @ptrFromInt(info_addr + offset);
        if (tag.type == TAG_END) break;
        if (tag.type == TAG_MMAP) {
            const t: *const MmapTag = @ptrFromInt(info_addr + offset);
            return .{
                .cursor = info_addr + offset + @sizeOf(MmapTag),
                .end = info_addr + offset + t.size,
                .entry_size = t.entry_size,
            };
        }
        offset += alignUp8(tag.size);
    }
    return null;
}

/// Total size in bytes of the boot info structure (for reserving it).
pub fn infoSize(info_addr: usize) usize {
    return @as(*const u32, @ptrFromInt(info_addr)).*;
}

/// Walk the tags looking for an RGB framebuffer (type 8, fb_type 1).
pub fn findFramebuffer(info_addr: usize) ?fb.Framebuffer {
    const total_size: u32 = @as(*const u32, @ptrFromInt(info_addr)).*;
    var offset: usize = 8;
    while (offset < total_size) {
        const tag: *const TagHeader = @ptrFromInt(info_addr + offset);
        if (tag.type == TAG_END) break;
        if (tag.type == TAG_FRAMEBUFFER) {
            const t: *const FramebufferTag = @ptrFromInt(info_addr + offset);
            if (t.fb_type == 1) { // RGB linear framebuffer
                return .{
                    .addr = @intCast(t.addr),
                    .pitch = t.pitch,
                    .width = t.width,
                    .height = t.height,
                    .bpp = t.bpp,
                };
            }
        }
        offset += alignUp8(tag.size);
    }
    return null;
}

/// Walk the boot-info tags and print the physical memory map.
pub fn parse(info_addr: usize) void {
    const total_size: u32 = @as(*const u32, @ptrFromInt(info_addr)).*;

    console.writeString("[mb2] boot info @ ");
    console.writeHex(info_addr);
    console.writeString(", size=");
    console.writeDec(total_size);
    console.writeString(" bytes\n");

    var offset: usize = 8; // skip total_size (u32) + reserved (u32)
    while (offset < total_size) {
        const tag: *const TagHeader = @ptrFromInt(info_addr + offset);
        if (tag.type == TAG_END) break;
        if (tag.type == TAG_MMAP) {
            printMmap(@ptrFromInt(info_addr + offset));
        }
        offset += alignUp8(tag.size);
    }
}

fn printMmap(tag: *const MmapTag) void {
    console.writeString("[mb2] physical memory map:\n");

    var total_available: u64 = 0;
    const entries_start = @intFromPtr(tag) + @sizeOf(MmapTag);
    const entries_end = @intFromPtr(tag) + tag.size;

    var addr = entries_start;
    while (addr + @sizeOf(MmapEntry) <= entries_end) : (addr += tag.entry_size) {
        const e: *const MmapEntry = @ptrFromInt(addr);

        console.writeString("        ");
        console.writeHex(e.base_addr);
        console.writeString(" - ");
        console.writeHex(e.base_addr + e.length);
        console.writeString("  ");
        console.writeString(typeName(e.type));
        console.writeString("\n");

        if (e.type == MEM_AVAILABLE) total_available += e.length;
    }

    console.writeString("[mb2] total available RAM: ");
    console.writeDec(total_available / (1024 * 1024));
    console.writeString(" MiB\n");
}

/// Find the first Multiboot2 module tag and return its physical address range.
/// Returns null if no module was provided by the bootloader (ATA path used).
pub fn findModule(info_addr: usize) ?Module {
    const total_size: u32 = @as(*const u32, @ptrFromInt(info_addr)).*;
    var offset: usize = 8;
    while (offset < total_size) {
        const tag: *const TagHeader = @ptrFromInt(info_addr + offset);
        if (tag.type == TAG_END) break;
        if (tag.type == TAG_MODULE) {
            const m: *const ModuleTag = @ptrFromInt(info_addr + offset);
            return .{ .start = m.mod_start, .end = m.mod_end };
        }
        offset += alignUp8(tag.size);
    }
    return null;
}
