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
const sched = @import("proc/sched.zig");
const process = @import("proc/process.zig");
const ata = @import("arch/x86_64/ata.zig");
const pci = @import("arch/x86_64/pci.zig");
const net = @import("net/net.zig");
const pic = @import("arch/x86_64/pic.zig");
const pit = @import("arch/x86_64/pit.zig");
const vfs = @import("fs/vfs.zig");
const syscall = @import("syscall/syscall.zig");
const usermode = @import("arch/x86_64/usermode.zig");
const users_mod = @import("proc/users.zig");

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
    console.writeString("  \x1b[1;36mNevara OS\x1b[0m  -  kernel\n");
    console.writeString("======================================\n");
    console.writeString("[boot] reached 64-bit long mode via GRUB/Multiboot2\n");
    if (have_fb) {
        console.writeString("[fb] framebuffer active ");
        // Print actual resolution GRUB gave us.
        if (multiboot2.findFramebuffer(info)) |fbinfo| {
            console.writeDec(fbinfo.width);
            console.writeString("x");
            console.writeDec(fbinfo.height);
            console.writeString("x");
            console.writeDec(fbinfo.bpp);
        }
        console.writeString("\n");
    } else {
        console.writeString("[fb] no usable framebuffer (serial only)\n");
    }

    if (magic == MULTIBOOT2_BOOTLOADER_MAGIC) {
        console.writeString("[boot] multiboot2 magic OK\n");
    } else {
        console.writeString("[boot] WARNING: bad multiboot2 magic\n");
    }

    gdt.init();
    idt.init();
    pic.init(); // remap + mask all IRQs; safe to enable interrupts afterwards

    if (magic == MULTIBOOT2_BOOTLOADER_MAGIC) {
        multiboot2.parse(info);
        pmm.init(info);
        testPmm();
        vmm.init();
        testVmm();
        heap.init();
        testHeap();
        vfs.init() catch {
            console.writeString("[vfs] init failed\n");
            hang();
        };
        console.writeString("[vfs] root tmpfs + /dev ready\n");

        _ = ata.init();
        pci.init();
        _ = net.init();
        // Enable IRQ11 (RTL8139 on PCI INTA).
        pic.unmask(11);

        // If GRUB loaded rootfs.ext4 as a Multiboot2 module (Ventoy / live ISO),
        // register it as a RAM disk. The ext4 driver prefers RAM over ATA.
        if (multiboot2.findModule(info)) |mod| {
            console.writeString("[boot] module found @ 0x");
            console.writeHex(mod.start);
            console.writeString(" size=");
            const mod_size = mod.end - mod.start;
            console.writeDec(mod_size / 1024);
            console.writeString(" KiB — using as rootfs ramdisk\n");
            const ext4 = @import("fs/ext4.zig");
            ext4.setRamdisk(mod.start, mod.end);
        }
        if (!vfs.mountExt4AsRoot()) {
            console.writeString("[boot] WARNING: ext4 rootfs not found\n");
            console.writeString("[boot] Check BIOS: set SATA mode to IDE/Legacy\n");
            console.writeString("[boot] Continuing without rootfs (shell unavailable)\n");
        }
        users_mod.loadPasswd();
        usermode.init();
        process.init(); // scheduler + the kernel (kmain) process, stdio bound

        // Turn on preemption (timer) and keyboard, then run userspace.
        pit.init(100);
        pic.unmask(0); // timer IRQ0 -> round-robin preemption
        pic.unmask(1); // keyboard
        asm volatile ("sti");

        console.writeString("[boot] starting /bin/zinit as PID 1\n");
        _ = process.spawnImage(@embedFile("zinit_elf"), &.{"/bin/zinit"});

        // The kmain process becomes the idle task: hand the CPU to the
        // user processes and halt whenever nothing else is runnable.
        while (true) {
            sched.yield();
            asm volatile ("hlt");
        }
    } else {
        console.writeString("[mb2] skipping memory map (not multiboot2-booted)\n");
    }

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
