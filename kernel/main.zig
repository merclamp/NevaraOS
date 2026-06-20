//! Nevara OS kernel — entry point.
//! Reached from the 32->64 bit trampoline in arch/x86_64/boot.S.

const std = @import("std");
const console = @import("arch/x86_64/console.zig");
const gdt = @import("arch/x86_64/gdt.zig");
const idt = @import("arch/x86_64/idt.zig");
const multiboot2 = @import("arch/x86_64/multiboot2.zig");
const pmm = @import("mm/pmm.zig");
const vmm = @import("mm/vmm.zig");
const heap = @import("mm/heap.zig");

comptime {
    _ = @import("lib/c.zig"); // export memcpy/memmove/memset/memcmp
}

/// Multiboot2 magic value a compliant bootloader leaves in eax.
const MULTIBOOT2_BOOTLOADER_MAGIC: u32 = 0x36d76289;

/// Kernel entry. `magic` and `info` come from GRUB via eax/ebx.
export fn kmain(magic: u32, info: u32) callconv(.c) noreturn {
    console.init();

    // Bring up the on-screen framebuffer console as early as possible so the
    // full boot log is visible on the monitor, not just the serial port.
    var have_fb = false;
    if (magic == MULTIBOOT2_BOOTLOADER_MAGIC) {
        if (multiboot2.findFramebuffer(info)) |framebuffer| {
            have_fb = console.useFramebuffer(framebuffer);
        }
    }

    console.writeString("\n");
    console.writeString("======================================\n");
    console.writeString("  Nevara OS  -  kernel\n");
    console.writeString("======================================\n");
    console.writeString("[boot] reached 64-bit long mode via GRUB/Multiboot2\n");
    if (have_fb) {
        console.writeString("[fb] framebuffer console active (1024x768x32)\n");
    } else {
        console.writeString("[fb] no usable framebuffer; serial only\n");
    }

    if (magic == MULTIBOOT2_BOOTLOADER_MAGIC) {
        console.writeString("[boot] multiboot2 magic OK\n");
    } else {
        console.writeString("[boot] WARNING: bad multiboot2 magic\n");
    }

    gdt.init();
    idt.init();

    if (magic == MULTIBOOT2_BOOTLOADER_MAGIC) {
        multiboot2.parse(info);
        pmm.init(info);
        testPmm();
        vmm.init();
        testVmm();
        heap.init();
        testHeap();
    } else {
        console.writeString("[mb2] skipping memory map (not multiboot2-booted)\n");
    }


    // Smoke-test the interrupt path: a breakpoint must be caught and resumed.
    console.writeString("[boot] triggering test breakpoint (int3)...\n");
    asm volatile ("int3");
    console.writeString("[boot] resumed after breakpoint\n");

    console.writeString("[boot] kmain alive, halting.\n");
    hang();
}

/// Park the CPU forever.
pub fn hang() noreturn {
    while (true) {
        asm volatile ("cli; hlt");
    }
}

/// Quick sanity check of the physical frame allocator.
fn testPmm() void {
    const a = pmm.alloc() orelse return;
    const b = pmm.alloc() orelse return;
    console.writeString("[pmm] test: alloc a=");
    console.writeHex(a);
    console.writeString(" b=");
    console.writeHex(b);
    pmm.free(a);
    const c = pmm.alloc() orelse return;
    console.writeString(", free(a)->alloc c=");
    console.writeHex(c);
    console.writeString(if (c == a) "  [reused OK]\n" else "  [WARN not reused]\n");
    pmm.free(b);
    pmm.free(c);
}

/// Map a fresh frame at 4 GiB, write/read through it, and verify translation.
fn testVmm() void {
    const virt: usize = 0x1_0000_0000; // 4 GiB: above the identity huge-page map
    const phys = pmm.alloc() orelse return;
    if (!vmm.map(virt, phys, vmm.WRITABLE)) {
        console.writeString("[vmm] test: map failed\n");
        return;
    }
    const vptr: *volatile u64 = @ptrFromInt(virt);
    vptr.* = 0xDEADBEEFCAFEBABE;
    const readback = vptr.*;
    const translated = vmm.walk(virt) orelse 0;
    const via_phys = @as(*volatile u64, @ptrFromInt(phys)).*;

    console.writeString("[vmm] test: virt=");
    console.writeHex(virt);
    console.writeString(" -> phys=");
    console.writeHex(translated);
    const ok = readback == 0xDEADBEEFCAFEBABE and translated == phys and via_phys == readback;
    console.writeString(if (ok) "  [map/translate OK]\n" else "  [FAIL]\n");

    vmm.unmap(virt);
    pmm.free(phys);
}

/// Exercise the kernel heap through the std.mem.Allocator interface.
fn testHeap() void {
    const a = heap.allocator();

    // Basic alloc, write, verify, free.
    const buf1 = a.alloc(u8, 64) catch {
        console.writeString("[heap] test: alloc failed\n");
        return;
    };
    for (buf1, 0..) |*x, i| x.* = @intCast(i & 0xFF);
    var sum: usize = 0;
    for (buf1) |x| sum += x;

    const buf2 = a.alloc(u8, 64) catch return;
    a.free(buf1);
    const buf3 = a.alloc(u8, 64) catch return; // should reuse buf1's slot

    console.writeString("[heap] test: buf1=");
    console.writeHex(@intFromPtr(buf1.ptr));
    console.writeString(" buf2=");
    console.writeHex(@intFromPtr(buf2.ptr));
    console.writeString(" free(buf1)->buf3=");
    console.writeHex(@intFromPtr(buf3.ptr));
    console.writeString(if (@intFromPtr(buf3.ptr) == @intFromPtr(buf1.ptr)) "  [reused OK]\n" else "  [no reuse]\n");

    a.free(buf2);
    a.free(buf3);

    // Force heap growth past the 64 KiB chunk, plus a typed create/destroy.
    const big = a.alloc(u8, 256 * 1024) catch {
        console.writeString("[heap] test: big alloc failed\n");
        return;
    };
    big[0] = 0xAB;
    big[big.len - 1] = 0xCD;
    const big_ok = big[0] == 0xAB and big[big.len - 1] == 0xCD;
    a.free(big);

    const Point = struct { x: u64, y: u64 };
    const p = a.create(Point) catch return;
    p.* = .{ .x = 11, .y = 31 };
    const created_ok = p.x + p.y == 42;
    a.destroy(p);

    console.writeString("[heap] test: 256KiB grow ");
    console.writeString(if (big_ok) "OK" else "FAIL");
    console.writeString(", typed create ");
    console.writeString(if (created_ok) "OK" else "FAIL");
    console.writeString(", committed=");
    console.writeDec(heap.committedBytes() / 1024);
    console.writeString(" KiB\n");
}

/// Minimal freestanding panic handler. Avoids std.fmt/Writer entirely so the
/// kernel does not drag formatting machinery into a no-OS target.
pub const panic = std.debug.FullPanic(struct {
    fn handler(msg: []const u8, _: ?usize) noreturn {
        console.writeString("\n[panic] ");
        console.writeString(msg);
        console.writeString("\n");
        hang();
    }
}.handler);
