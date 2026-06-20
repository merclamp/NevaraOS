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

fn service(path: [*:0]const u8, argv: []const ?[*:0]const u8) void {
    nstd.print("[zinit] spawn ");
    nstd.print(nstd.span(path));
    nstd.print("\n");
    const code = nstd.spawn(path, argv.ptr);
    nstd.print("[zinit]   -> exit ");
    if (code < 0) {
        nstd.print("-");
        nstd.printDec(@intCast(-code));
    } else {
        nstd.printDec(@intCast(code));
    }
    nstd.print("\n");
}

pub fn main() void {
    nstd.print("[zinit] PID 1 up; bringing up Nevara userland\n");

    const echo = [_]?[*:0]const u8{ "echo", "ZInit", "launched", "NevBox", null };
    service("/bin/nevbox", &echo);

    const ls = [_]?[*:0]const u8{ "ls", "/bin", null };
    service("/bin/nevbox", &ls);

    const cat = [_]?[*:0]const u8{ "cat", "/etc/hostname", null };
    service("/bin/nevbox", &cat);

    const hello = [_]?[*:0]const u8{ "/bin/hello", null };
    service("/bin/hello", &hello);

    nstd.print("[zinit] all services exited; init idle\n");
}
