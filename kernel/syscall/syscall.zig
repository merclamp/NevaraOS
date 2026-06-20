//! Linux-compatible system call layer.
//!
//! Provides a per-task file-descriptor table, a dispatcher keyed by the Linux
//! x86_64 syscall numbers, and handlers that operate on the VFS. For now there
//! is a single global descriptor table (one kernel task); it becomes per-process
//! once we have userspace. The actual `syscall`-instruction entry from ring 3 is
//! wired up in the userspace phase; until then the dispatcher is the entry
//! point, callable directly with Linux-style register arguments.

const std = @import("std");
const vfs = @import("../fs/vfs.zig");
const sched = @import("../proc/sched.zig");

// Linux x86_64 syscall numbers (subset).
const SYS_read: usize = 0;
const SYS_write: usize = 1;
const SYS_open: usize = 2;
const SYS_close: usize = 3;
const SYS_lseek: usize = 8;
const SYS_getpid: usize = 39;
const SYS_exit: usize = 60;
const SYS_mkdir: usize = 83;

// errno values (returned negated).
const ENOENT: isize = 2;
const EBADF: isize = 9;
const EEXIST: isize = 17;
const ENOTDIR: isize = 20;
const EISDIR: isize = 21;
const EINVAL: isize = 22;
const ENOSYS: isize = 38;

// open() flags.
const O_CREAT: usize = 0o100;
const O_TRUNC: usize = 0o1000;
const O_APPEND: usize = 0o2000;

// lseek() whence.
const SEEK_SET: usize = 0;
const SEEK_CUR: usize = 1;
const SEEK_END: usize = 2;

const MAX_FD = 64;

const File = struct {
    node: *vfs.Node = undefined,
    offset: usize = 0,
    used: bool = false,
};

var fds: [MAX_FD]File = .{File{}} ** MAX_FD;

fn errnoFor(e: vfs.Error) isize {
    return -switch (e) {
        error.NotFound => ENOENT,
        error.NotDirectory => ENOTDIR,
        error.IsDirectory => EISDIR,
        error.Exists => EEXIST,
        error.Invalid => EINVAL,
        else => ENOSYS,
    };
}

fn allocFd() ?usize {
    var i: usize = 3; // 0,1,2 reserved for stdio
    while (i < MAX_FD) : (i += 1) {
        if (!fds[i].used) return i;
    }
    return null;
}

fn cstr(ptr: usize) []const u8 {
    const p: [*:0]const u8 = @ptrFromInt(ptr);
    return std.mem.span(p);
}

/// Bind stdin/stdout/stderr to /dev/console.
pub fn init() void {
    const con = vfs.resolve("/dev/console") catch return;
    for (0..3) |i| fds[i] = .{ .node = con, .offset = 0, .used = true };
}

fn sysWrite(fd: usize, buf_ptr: usize, count: usize) isize {
    if (fd >= MAX_FD or !fds[fd].used) return -EBADF;
    const buf: [*]const u8 = @ptrFromInt(buf_ptr);
    const f = &fds[fd];
    const n = vfs.writeAt(f.node, buf[0..count], f.offset) catch |e| return errnoFor(e);
    if (f.node.kind == .file) f.offset += n;
    return @intCast(n);
}

fn sysRead(fd: usize, buf_ptr: usize, count: usize) isize {
    if (fd >= MAX_FD or !fds[fd].used) return -EBADF;
    const buf: [*]u8 = @ptrFromInt(buf_ptr);
    const f = &fds[fd];
    const n = vfs.readAt(f.node, buf[0..count], f.offset) catch |e| return errnoFor(e);
    if (f.node.kind == .file) f.offset += n;
    return @intCast(n);
}

fn sysOpen(path_ptr: usize, flags: usize) isize {
    const path = cstr(path_ptr);
    var node = vfs.resolve(path) catch |e| blk: {
        if (e == error.NotFound and (flags & O_CREAT) != 0) {
            break :blk vfs.create(path, .file) catch |ce| return errnoFor(ce);
        }
        return errnoFor(e);
    };
    if ((flags & O_TRUNC) != 0 and node.kind == .file) node.size = 0;
    const fd = allocFd() orelse return -EBADF;
    const start: usize = if ((flags & O_APPEND) != 0) node.size else 0;
    fds[fd] = .{ .node = node, .offset = start, .used = true };
    return @intCast(fd);
}

fn sysClose(fd: usize) isize {
    if (fd >= MAX_FD or !fds[fd].used) return -EBADF;
    if (fd > 2) fds[fd].used = false; // keep stdio open
    return 0;
}

fn sysLseek(fd: usize, offset: usize, whence: usize) isize {
    if (fd >= MAX_FD or !fds[fd].used) return -EBADF;
    const f = &fds[fd];
    const base: usize = switch (whence) {
        SEEK_SET => 0,
        SEEK_CUR => f.offset,
        SEEK_END => f.node.size,
        else => return -EINVAL,
    };
    f.offset = base + offset;
    return @intCast(f.offset);
}

fn sysMkdir(path_ptr: usize) isize {
    _ = vfs.mkdir(cstr(path_ptr)) catch |e| return errnoFor(e);
    return 0;
}

/// Central dispatcher: invoked with Linux-style register arguments.
pub fn dispatch(num: usize, a1: usize, a2: usize, a3: usize) isize {
    return switch (num) {
        SYS_read => sysRead(a1, a2, a3),
        SYS_write => sysWrite(a1, a2, a3),
        SYS_open => sysOpen(a1, a2),
        SYS_close => sysClose(a1),
        SYS_lseek => sysLseek(a1, a2, a3),
        SYS_getpid => @intCast(sched.currentThread().id),
        SYS_exit => 0, // no userspace yet; nothing to tear down
        SYS_mkdir => sysMkdir(a1),
        else => -ENOSYS,
    };
}
