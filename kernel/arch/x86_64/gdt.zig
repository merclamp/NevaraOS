//! Global Descriptor Table (x86_64).
//!
//! In long mode segmentation is mostly vestigial — code/data segments are flat
//! — but we still need a real GDT for:
//!   * a kernel code/data pair (ring 0),
//!   * a user code/data pair (ring 3, for later userspace),
//!   * a TSS holding RSP0 / IST stacks (required before we take interrupts or
//!     ever switch to ring 3).
//!
//! This replaces the throwaway 2-entry GDT the boot trampoline used.

const console = @import("console.zig");

/// Segment selectors (index << 3 | RPL).
pub const KERNEL_CODE: u16 = 0x08;
pub const KERNEL_DATA: u16 = 0x10;
pub const USER_CODE: u16 = 0x23; // index 4, RPL 3
pub const USER_DATA: u16 = 0x1B; // index 3, RPL 3
pub const TSS_SELECTOR: u16 = 0x28; // index 5

/// 64-bit Task State Segment. Field offsets are unaligned, so this must be a
/// packed struct to match the hardware layout exactly (104 bytes).
const Tss = packed struct {
    reserved0: u32 = 0,
    rsp0: u64 = 0,
    rsp1: u64 = 0,
    rsp2: u64 = 0,
    reserved1: u64 = 0,
    ist1: u64 = 0,
    ist2: u64 = 0,
    ist3: u64 = 0,
    ist4: u64 = 0,
    ist5: u64 = 0,
    ist6: u64 = 0,
    ist7: u64 = 0,
    reserved2: u64 = 0,
    reserved3: u16 = 0,
    iopb: u16 = 0,
};

/// The `lgdt` operand: 16-bit limit followed by a 64-bit base, no padding.
const GdtPointer = packed struct {
    limit: u16,
    base: u64,
};

// GDT layout:
//   [0] null
//   [1] kernel code   (0x08)
//   [2] kernel data   (0x10)
//   [3] user data     (0x1B)
//   [4] user code     (0x23)
//   [5]+[6] TSS       (0x28, 16-byte system descriptor)
var gdt: [7]u64 = .{
    0x0000000000000000, // null
    0x00AF9A000000FFFF, // kernel code: P, DPL0, exec, long-mode (L)
    0x00CF92000000FFFF, // kernel data: P, DPL0, writable
    0x00CFF2000000FFFF, // user data:   P, DPL3, writable
    0x00AFFA000000FFFF, // user code:   P, DPL3, exec, long-mode (L)
    0x0000000000000000, // TSS low  (filled at runtime)
    0x0000000000000000, // TSS high (filled at runtime)
};

var tss: Tss = .{};

/// Dedicated stack used for RSP0 (the stack the CPU switches to on a ring3->0
/// transition). 16 KiB is plenty for early kernel work.
var kernel_stack: [16 * 1024]u8 align(16) = undefined;

var gdtr: GdtPointer = undefined;

/// Build the 16-byte TSS system descriptor in slots [5] and [6].
fn encodeTssDescriptor(base: u64, limit: u32) void {
    const access: u64 = 0x89; // present, type = 0x9 (available 64-bit TSS)
    const flags: u64 = 0x0; // byte granularity

    var low: u64 = 0;
    low |= (limit & 0xFFFF);
    low |= (base & 0xFFFF) << 16;
    low |= ((base >> 16) & 0xFF) << 32;
    low |= access << 40;
    low |= (((limit >> 16) & 0xF) | (flags << 4)) << 48;
    low |= ((base >> 24) & 0xFF) << 56;

    const high: u64 = (base >> 32) & 0xFFFFFFFF;

    gdt[5] = low;
    gdt[6] = high;
}

/// Install the GDT, reload all segment registers, and load the TSS.
pub fn init() void {
    // Point RSP0 at the top of our kernel stack (stack grows downward).
    tss.rsp0 = @intFromPtr(&kernel_stack) + kernel_stack.len;
    tss.iopb = @sizeOf(Tss); // no I/O permission bitmap

    encodeTssDescriptor(@intFromPtr(&tss), @sizeOf(Tss) - 1);

    gdtr = .{
        .limit = @sizeOf(@TypeOf(gdt)) - 1,
        .base = @intFromPtr(&gdt),
    };

    gdt_flush(&gdtr);
    tss_flush(TSS_SELECTOR);

    console.writeString("[gdt] GDT loaded, segments reloaded, TSS active\n");
}

// Implemented in flush.S — Zig 0.16 inline asm cannot express these safely.
extern fn gdt_flush(ptr: *const GdtPointer) void;
extern fn tss_flush(selector: u16) void;
