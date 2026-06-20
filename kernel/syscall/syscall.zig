//! Linux-compatible system call layer.
//!
//! Dispatches on the Linux x86_64 syscall numbers. File descriptors and the
//! program break live in the per-process state (proc/process.zig); process
//! control (fork/execve/wait4/exit) is delegated there too.

const std = @import("std");
const vfs = @import("../fs/vfs.zig");
const sched = @import("../proc/sched.zig");
const process = @import("../proc/process.zig");
const pmm = @import("../mm/pmm.zig");
const vmm = @import("../mm/vmm.zig");
const heap = @import("../mm/heap.zig");
const usermode = @import("../arch/x86_64/usermode.zig");

// Linux x86_64 syscall numbers (subset).
const SYS_read: usize = 0;
const SYS_write: usize = 1;
const SYS_open: usize = 2;
const SYS_close: usize = 3;
const SYS_lseek: usize = 8;
const SYS_brk: usize = 12;
const SYS_getpid: usize = 39;
const SYS_fork: usize = 57;
const SYS_execve: usize = 59;
const SYS_exit: usize = 60;
const SYS_wait4: usize = 61;
const SYS_mkdir: usize = 83;
const SYS_getdents64: usize = 217;
const SYS_spawn: usize = 1000;

// errno values (returned negated).
const ENOENT: isize = 2;
const EBADF: isize = 9;
const ECHILD: isize = 10;
const ENOMEM: isize = 12;
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

// User program break base (per process; each has its own address space).
const USER_HEAP_BASE: usize = 0x4000_1000_0000;

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

fn fdTable() *[process.MAX_FD]process.File {
    return &process.current().fds;
}

fn allocFd() ?usize {
    const fds = fdTable();
    var i: usize = 3; // 0,1,2 reserved for stdio
    while (i < process.MAX_FD) : (i += 1) {
        if (!fds[i].used) return i;
    }
    return null;
}

fn cstr(ptr: usize) []const u8 {
    const p: [*:0]const u8 = @ptrFromInt(ptr);
    return std.mem.span(p);
}

fn sysWrite(fd: usize, buf_ptr: usize, count: usize) isize {
    const fds = fdTable();
    if (fd >= process.MAX_FD or !fds[fd].used) return -EBADF;
    const buf: [*]const u8 = @ptrFromInt(buf_ptr);
    const f = &fds[fd];
    const n = vfs.writeAt(f.node, buf[0..count], f.offset) catch |e| return errnoFor(e);
    if (f.node.kind == .file) f.offset += n;
    return @intCast(n);
}

fn sysRead(fd: usize, buf_ptr: usize, count: usize) isize {
    const fds = fdTable();
    if (fd >= process.MAX_FD or !fds[fd].used) return -EBADF;
    const buf: [*]u8 = @ptrFromInt(buf_ptr);
    const f = &fds[fd];
    const n = vfs.readAt(f.node, buf[0..count], f.offset) catch |e| return errnoFor(e);
    if (f.node.kind == .file) f.offset += n;
    return @intCast(n);
}

fn sysOpen(path_ptr: usize, flags: usize) isize {
    const path = cstr(path_ptr);
    const node = vfs.resolve(path) catch |e| blk: {
        if (e == error.NotFound and (flags & O_CREAT) != 0) {
            break :blk vfs.create(path, .file) catch |ce| return errnoFor(ce);
        }
        return errnoFor(e);
    };
    if ((flags & O_TRUNC) != 0 and node.kind == .file) node.size = 0;
    const fd = allocFd() orelse return -EBADF;
    const start: usize = if ((flags & O_APPEND) != 0) node.size else 0;
    fdTable()[fd] = .{ .node = node, .offset = start, .used = true };
    return @intCast(fd);
}

fn sysClose(fd: usize) isize {
    const fds = fdTable();
    if (fd >= process.MAX_FD or !fds[fd].used) return -EBADF;
    if (fd > 2) fds[fd].used = false; // keep stdio open
    return 0;
}

fn sysLseek(fd: usize, offset: usize, whence: usize) isize {
    const fds = fdTable();
    if (fd >= process.MAX_FD or !fds[fd].used) return -EBADF;
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

// Linux dirent type values.
const DT_CHR: u8 = 2;
const DT_DIR: u8 = 4;
const DT_REG: u8 = 8;

inline fn alignUp8(v: usize) usize {
    return (v + 7) & ~@as(usize, 7);
}

fn sysGetdents64(fd: usize, buf_ptr: usize, count: usize) isize {
    const fds = fdTable();
    if (fd >= process.MAX_FD or !fds[fd].used) return -EBADF;
    const f = &fds[fd];
    const dir = f.node;
    if (dir.kind != .dir) return -ENOTDIR;

    const out: [*]u8 = @ptrFromInt(buf_ptr);
    var written: usize = 0;

    while (vfs.readdir(dir, f.offset)) |child| {
        const name = child.name;
        const reclen = alignUp8(19 + name.len + 1);
        if (written + reclen > count) break;

        const base = out + written;
        @memset(base[0..reclen], 0);
        std.mem.writeInt(u64, base[0..8], @intFromPtr(child), .little);
        std.mem.writeInt(i64, base[8..16], @intCast(f.offset + 1), .little);
        std.mem.writeInt(u16, base[16..18], @intCast(reclen), .little);
        base[18] = switch (child.kind) {
            .dir => DT_DIR,
            .chardev => DT_CHR,
            .file => DT_REG,
        };
        @memcpy(base[19 .. 19 + name.len], name);

        written += reclen;
        f.offset += 1;
    }
    return @intCast(written);
}

/// brk(addr): set the program break. addr==0 queries it. Grows by mapping fresh
/// user pages in the current process's address space.
fn sysBrk(addr: usize) isize {
    const p = process.current();
    if (p.brk == 0) p.brk = USER_HEAP_BASE;
    if (addr == 0 or addr < USER_HEAP_BASE) return @intCast(p.brk);

    const flags = vmm.PRESENT | vmm.WRITABLE | vmm.USER;
    var page = (p.brk + 0xFFF) & ~@as(usize, 0xFFF);
    while (page < addr) : (page += 0x1000) {
        if (vmm.walk(page) == null) {
            const frame = pmm.alloc() orelse return @intCast(p.brk);
            if (!vmm.map(page, frame, flags)) return @intCast(p.brk);
            @memset(@as([*]u8, @ptrFromInt(page))[0..0x1000], 0);
        }
    }
    p.brk = addr;
    return @intCast(addr);
}

/// spawn(path, argv): convenience for a blocking run — create a child process
/// from the image and wait for it. Returns its exit code.
fn sysSpawn(path_ptr: usize, argv_ptr: usize) isize {
    const path = cstr(path_ptr);
    const node = vfs.resolve(path) catch |e| return errnoFor(e);
    if (node.kind != .file) return -EINVAL;
    const image = node.data[0..node.size];

    const a = heap.allocator();
    var bufs: [16][]u8 = undefined;
    var args: [16][]const u8 = undefined;
    var n: usize = 0;
    if (argv_ptr != 0) {
        const argv: [*]const usize = @ptrFromInt(argv_ptr);
        while (n < 16 and argv[n] != 0) : (n += 1) {
            const s = cstr(argv[n]);
            const buf = a.alloc(u8, s.len) catch break;
            @memcpy(buf, s);
            bufs[n] = buf;
            args[n] = buf;
        }
    }

    const pid = process.spawnImage(image, args[0..n]);

    var i: usize = 0;
    while (i < n) : (i += 1) a.free(bufs[i]);

    if (pid < 0) return -1;
    var status: u32 = 0;
    _ = process.wait4(pid, @intFromPtr(&status), 0);
    return @intCast((status >> 8) & 0xFF);
}

/// Central dispatcher, invoked from the SYSCALL handler with a saved trap frame.
/// Returns the value to place in the caller's rax (exit/execve do not return).
pub fn handle(tf: *usermode.TrapFrame) isize {
    const num = tf.rax;
    const a1 = tf.rdi;
    const a2 = tf.rsi;
    const a3 = tf.rdx;
    return switch (num) {
        SYS_read => sysRead(a1, a2, a3),
        SYS_write => sysWrite(a1, a2, a3),
        SYS_open => sysOpen(a1, a2),
        SYS_close => sysClose(a1),
        SYS_lseek => sysLseek(a1, a2, a3),
        SYS_brk => sysBrk(a1),
        SYS_getpid => @intCast(process.current().pid),
        SYS_fork => process.fork(tf),
        SYS_execve => process.exec(cstr(a1), a2),
        SYS_exit => process.exit(@bitCast(@as(u32, @truncate(a1)))),
        SYS_wait4 => process.wait4(@bitCast(a1), a2, a3),
        SYS_mkdir => sysMkdir(a1),
        SYS_getdents64 => sysGetdents64(a1, a2, a3),
        SYS_spawn => sysSpawn(a1, a2),
        else => -ENOSYS,
    };
}
