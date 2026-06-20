//! Nevara OS — first userspace program, built on the nstd runtime (no C libc).

const nstd = @import("nstd");

export fn _start() callconv(.naked) noreturn {
    asm volatile (
        \\ movq (%rsp), %rdi
        \\ leaq 8(%rsp), %rsi
        \\ call startMain
    );
}

export fn startMain(c: usize, v: [*]const ?[*:0]const u8) callconv(.c) noreturn {
    nstd.start(c, v);
}

pub fn main() void {
    nstd.print("  [init] hello from nstd userland (ring 3, no libc)!\n");

    // Show the arguments the kernel handed us.
    nstd.print("  [init] argc=");
    nstd.printDec(nstd.argc());
    nstd.print(" argv:");
    var i: usize = 0;
    while (nstd.arg(i)) |a| : (i += 1) {
        nstd.print(" ");
        nstd.print(a);
    }
    nstd.print("\n");

    // brk-backed allocator still works.
    const alloc = nstd.allocator();
    const buf = alloc.alloc(u8, 26) catch return;
    for (buf, 0..) |*c, k| c.* = @intCast('a' + k);
    nstd.print("  [init] alloc demo: ");
    nstd.print(buf);
    nstd.print("\n  [init] goodbye\n");
}
