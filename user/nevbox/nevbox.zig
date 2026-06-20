//! NevBox — Nevara's multi-call userland utility (BusyBox-style), on nstd.
//!
//! One binary, many applets, dispatched by argv[0]'s basename. No C, no libc.

const std = @import("std");
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

fn basename(path: []const u8) []const u8 {
    var start: usize = 0;
    var i: usize = 0;
    while (i < path.len) : (i += 1) {
        if (path[i] == '/') start = i + 1;
    }
    return path[start..];
}

pub fn main() void {
    const argv0 = nstd.arg(0) orelse "nevbox";
    const cmd = basename(argv0);

    if (std.mem.eql(u8, cmd, "echo")) {
        appletEcho();
    } else if (std.mem.eql(u8, cmd, "cat")) {
        appletCat();
    } else if (std.mem.eql(u8, cmd, "ls")) {
        appletLs();
    } else if (std.mem.eql(u8, cmd, "mkfile")) {
        appletMkfile();
    } else if (std.mem.eql(u8, cmd, "mkdir")) {
        appletMkdir();
    } else {
        nstd.print("nevbox: applets: echo, cat, ls, mkfile, mkdir\n");
    }
}

fn appletEcho() void {
    var i: usize = 1;
    while (nstd.arg(i)) |a| : (i += 1) {
        if (i > 1) nstd.print(" ");
        nstd.print(a);
    }
    nstd.print("\n");
}

fn appletMkfile() void {
    const path = nstd.argZ(1) orelse {
        nstd.print("usage: mkfile <path> <text...>\n");
        return;
    };
    const fd = nstd.open(path, 0o100 | 0o1000); // O_CREAT | O_TRUNC
    if (fd < 0) {
        nstd.print("mkfile: cannot create file\n");
        return;
    }
    var i: usize = 2;
    var first = true;
    while (nstd.arg(i)) |a| : (i += 1) {
        if (!first) _ = nstd.write(@intCast(fd), " ");
        _ = nstd.write(@intCast(fd), a);
        first = false;
    }
    _ = nstd.write(@intCast(fd), "\n");
    nstd.close(@intCast(fd));
}

fn appletMkdir() void {
    var i: usize = 1;
    var any = false;
    while (nstd.argZ(i)) |path| : (i += 1) {
        any = true;
        if (nstd.mkdir(path) < 0) {
            nstd.print("mkdir: cannot create ");
            nstd.print(nstd.arg(i).?);
            nstd.print("\n");
        }
    }
    if (!any) nstd.print("usage: mkdir <dir>...\n");
}

fn appletCat() void {
    var i: usize = 1;
    while (nstd.argZ(i)) |path| : (i += 1) {
        const fd = nstd.open(path, 0);
        if (fd < 0) {
            nstd.print("cat: cannot open ");
            nstd.print(nstd.arg(i).?);
            nstd.print("\n");
            continue;
        }
        var buf: [256]u8 = undefined;
        while (true) {
            const n = nstd.read(@intCast(fd), &buf);
            if (n == 0) break;
            _ = nstd.write(1, buf[0..n]);
        }
        nstd.close(@intCast(fd));
    }
}

fn appletLs() void {
    if (nstd.argc() <= 1) {
        listDir("/");
    } else {
        var i: usize = 1;
        while (nstd.argZ(i)) |p| : (i += 1) listDir(p);
    }
}

fn listDir(path: [*:0]const u8) void {
    const fd = nstd.open(path, 0);
    if (fd < 0) {
        nstd.print("ls: cannot open directory\n");
        return;
    }
    var buf: [1024]u8 = undefined;
    while (true) {
        const n = nstd.getdents64(@intCast(fd), &buf);
        if (n <= 0) break;
        var off: usize = 0;
        const total: usize = @intCast(n);
        while (off < total) {
            const reclen = std.mem.readInt(u16, buf[off + 16 .. off + 18][0..2], .little);
            const name_ptr: [*:0]const u8 = @ptrCast(&buf[off + 19]);
            var len: usize = 0;
            while (name_ptr[len] != 0) len += 1;
            nstd.print(name_ptr[0..len]);
            nstd.print("  ");
            off += reclen;
        }
    }
    nstd.print("\n");
    nstd.close(@intCast(fd));
}
