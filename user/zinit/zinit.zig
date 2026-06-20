//! ZInit — Nevara's init system (PID 1), on the nstd runtime.
//!
//! Launches userland services as isolated child processes via spawn() and
//! reports their exit codes. (Synchronous supervision for now.)

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
    nstd.print("[zinit] PID 1 up; starting the shell\n");

    // getty-style: run the shell, respawn it whenever it exits.
    const shargv = [_]?[*:0]const u8{ "/bin/nsh", null };
    while (true) {
        _ = nstd.spawn("/bin/nsh", &shargv);
        nstd.print("[zinit] shell exited; restarting\n");
    }
}
