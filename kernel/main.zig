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
const pic = @import("arch/x86_64/pic.zig");
const pit = @import("arch/x86_64/pit.zig");
const vfs = @import("fs/vfs.zig");
const syscall = @import("syscall/syscall.zig");
const usermode = @import("arch/x86_64/usermode.zig");
const elf = @import("exec/elf.zig");

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
    pic.init(); // remap + mask all IRQs; safe to enable interrupts afterwards

    if (magic == MULTIBOOT2_BOOTLOADER_MAGIC) {
        multiboot2.parse(info);
        pmm.init(info);
        testPmm();
        vmm.init();
        testVmm();
        heap.init();
        testHeap();
        testSched();
        testPreempt();
        testVfs();
        testSyscall();
        usermode.init();
        pic.unmask(1); // enable the keyboard so the shell can read input
        installBinaries();
        runZInit();
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

fn worker(comptime tag: []const u8, comptime rounds: usize) fn () void {
    return struct {
        fn run() void {
            var i: usize = 0;
            while (i < rounds) : (i += 1) {
                console.writeString("    [" ++ tag ++ "] tick\n");
                sched.yield();
            }
            console.writeString("    [" ++ tag ++ "] done\n");
        }
    }.run;
}

/// Spawn a few cooperative kernel threads and run them round-robin to completion.
fn testSched() void {
    console.writeString("[sched] starting cooperative threads A, B, C\n");
    sched.init();
    _ = sched.spawn(worker("A", 3)) catch return;
    _ = sched.spawn(worker("B", 3)) catch return;
    _ = sched.spawn(worker("C", 2)) catch return;

    while (sched.runnableOthers() > 0) sched.yield();

    console.writeString("[sched] all threads finished, back in kmain\n");
}

/// A CPU-bound worker that never yields — only the timer can take the CPU away.
fn busyWorker(comptime tag: []const u8, comptime chunks: usize) fn () void {
    return struct {
        fn run() void {
            var c: usize = 0;
            while (c < chunks) : (c += 1) {
                // Burn time so a few timer ticks land inside this chunk.
                var spin: usize = 0;
                while (spin < 5_000_000) : (spin += 1) {
                    asm volatile ("" ::: .{ .memory = true });
                }
                console.writeString("    [" ++ tag ++ "] chunk\n");
            }
            console.writeString("    [" ++ tag ++ "] done\n");
        }
    }.run;
}

/// Preemptive test: CPU-bound threads that never yield, switched by the timer.
fn testPreempt() void {
    console.writeString("[sched] preemptive test: timer-driven (100 Hz)\n");
    sched.init();
    _ = sched.spawn(busyWorker("X", 3)) catch return;
    _ = sched.spawn(busyWorker("Y", 3)) catch return;
    _ = sched.spawn(busyWorker("Z", 3)) catch return;

    pit.init(100); // 100 Hz timer
    pic.unmask(0); // enable IRQ0
    asm volatile ("sti");

    while (sched.runnableOthers() > 0) asm volatile ("hlt");

    asm volatile ("cli");
    pic.mask(0);
    console.writeString("[sched] preemptive test done, ticks=");
    console.writeDec(sched.ticks);
    console.writeString("\n");
}

/// Exercise the in-memory VFS: directories, files, devices, and path lookup.
fn testVfs() void {
    vfs.init() catch {
        console.writeString("[vfs] init failed\n");
        return;
    };
    console.writeString("[vfs] mounted in-memory root with /dev\n");

    _ = vfs.mkdir("/etc") catch return;
    const f = vfs.create("/etc/hostname", .file) catch return;
    _ = vfs.writeAt(f, "nevara\n", 0) catch return;

    var buf: [64]u8 = undefined;
    const node = vfs.resolve("/etc/hostname") catch return;
    const n = vfs.readAt(node, &buf, 0) catch return;
    console.writeString("[vfs] /etc/hostname -> \"");
    var i: usize = 0;
    while (i < n) : (i += 1) {
        if (buf[i] == '\n') break;
        console.writeByte(buf[i]);
    }
    console.writeString("\" (");
    console.writeDec(node.size);
    console.writeString(" bytes)\n");

    // Directory listing of /
    console.writeString("[vfs] ls / :");
    var idx: usize = 0;
    while (vfs.readdir(vfs.root(), idx)) |child| : (idx += 1) {
        console.writeString(" ");
        console.writeString(child.name);
        if (child.kind == .dir) console.writeString("/");
    }
    console.writeString("\n");

    // /dev/zero yields zeros; /dev/null swallows writes.
    var zbuf: [8]u8 = .{ 0xAA, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA };
    const zn = vfs.resolve("/dev/zero") catch return;
    _ = vfs.readAt(zn, &zbuf, 0) catch return;
    const nn = vfs.resolve("/dev/null") catch return;
    const wrote = vfs.writeAt(nn, "discarded", 0) catch return;
    console.writeString("[vfs] /dev/zero[0]=");
    console.writeDec(zbuf[0]);
    console.writeString(", /dev/null wrote=");
    console.writeDec(wrote);
    console.writeString("\n");
}

/// Drive the syscall layer the way userspace will: Linux numbers + arguments.
fn testSyscall() void {
    syscall.init(); // bind stdin/stdout/stderr to /dev/console

    // write(1, ...) -> console
    const greeting = "  [syscall] hello from sys_write(1)\n";
    _ = syscall.dispatch(1, 1, @intFromPtr(greeting.ptr), greeting.len);

    // mkdir("/tmp"); open("/tmp/a", O_CREAT|O_RDWR)
    _ = syscall.dispatch(83, @intFromPtr("/tmp"), 0, 0);
    const fd = syscall.dispatch(2, @intFromPtr("/tmp/a"), 0o100 | 2, 0);

    // write payload, seek to start, read it back
    const payload = "syscall-io";
    _ = syscall.dispatch(1, @intCast(fd), @intFromPtr(payload.ptr), payload.len);
    _ = syscall.dispatch(8, @intCast(fd), 0, 0); // lseek SEEK_SET 0

    var buf: [16]u8 = undefined;
    const got = syscall.dispatch(0, @intCast(fd), @intFromPtr(&buf), payload.len);
    _ = syscall.dispatch(3, @intCast(fd), 0, 0); // close

    const pid = syscall.dispatch(39, 0, 0, 0); // getpid
    const bad = syscall.dispatch(2, @intFromPtr("/nope/x"), 2, 0); // ENOENT path

    console.writeString("[syscall] fd=");
    console.writeDec(@intCast(fd));
    console.writeString(" read ");
    console.writeDec(@intCast(got));
    console.writeString(" bytes \"");
    var i: usize = 0;
    while (i < @as(usize, @intCast(got))) : (i += 1) console.writeByte(buf[i]);
    console.writeString("\" getpid=");
    console.writeDec(@intCast(pid));
    console.writeString(", open(bad)=");
    console.writeDec(@intCast(-bad));
    console.writeString(" (errno)\n");
}

/// Write the embedded userland binaries into /bin (tmpfs) so the spawn syscall
/// can load them by path. NevBox is installed under several applet names
/// (BusyBox-style) so the shell can run /bin/ls, /bin/cat, /bin/echo.
fn installBinaries() void {
    _ = vfs.mkdir("/bin") catch {};
    install("/bin/zinit", @embedFile("zinit_elf"));
    install("/bin/nsh", @embedFile("nsh_elf"));
    install("/bin/hello", @embedFile("hello_elf"));
    install("/bin/init", @embedFile("init_elf"));
    const nevbox = @embedFile("nevbox_elf");
    install("/bin/nevbox", nevbox);
    install("/bin/echo", nevbox);
    install("/bin/cat", nevbox);
    install("/bin/ls", nevbox);
}

fn install(path: []const u8, bytes: []const u8) void {
    const f = vfs.create(path, .file) catch return;
    _ = vfs.writeAt(f, bytes, 0) catch {};
}

/// Launch ZInit (PID 1). It spawns the rest of userland as isolated processes.
fn runZInit() void {
    console.writeString("[boot] starting /bin/zinit as PID 1\n");
    _ = usermode.spawnImage(@embedFile("zinit_elf"), &.{"/bin/zinit"});
    console.writeString("[boot] init exited\n");
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
