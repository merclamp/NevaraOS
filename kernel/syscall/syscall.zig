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
const pit = @import("../arch/x86_64/pit.zig");


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
const SYS_pipe: usize = 22;
const SYS_dup2: usize = 33;
const SYS_getdents64: usize = 217;
const SYS_getcwd: usize = 79;
const SYS_chdir: usize = 80;
const SYS_spawn: usize = 1000;
const SYS_uptime: usize = 1001;
const SYS_unlink: usize = 87;
const SYS_rename: usize = 82;
const SYS_sleep:  usize = 1002;
const SYS_rmdir:  usize = 84;



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
const ERANGE: isize = 34;
const ENAMETOOLONG: isize = 36;
const ENOTEMPTY: isize = 39;



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
        error.NotFound    => ENOENT,
        error.NotDirectory => ENOTDIR,
        error.IsDirectory => EISDIR,
        error.NotEmpty    => ENOTEMPTY,
        error.Exists      => EEXIST,
        error.Invalid     => EINVAL,
        else              => ENOSYS,
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

// ---- Path resolution --------------------------------------------------------

/// Normalize an absolute path in-place, collapsing '.' and '..' components.
/// Writes into `buf` (512 bytes), returns a null-terminated slice or null on
/// overflow / empty input.
fn normPath(path: []const u8, buf: *[512]u8) ?[]const u8 {
    var len: usize = 1;
    buf[0] = '/';
    var it = std.mem.tokenizeScalar(u8, path, '/');
    while (it.next()) |comp| {
        if (comp.len == 0 or std.mem.eql(u8, comp, ".")) continue;
        if (std.mem.eql(u8, comp, "..")) {
            // Strip the last path component from buf[0..len].
            if (len > 1) {
                len -= 1;
                while (len > 1 and buf[len - 1] != '/') len -= 1;
                if (len > 1) len -= 1; // remove the '/' separator too
            }
            continue;
        }
        const sep: usize = if (len > 1) 1 else 0;
        if (len + sep + comp.len >= buf.len - 1) return null;
        if (sep > 0) { buf[len] = '/'; len += 1; }
        @memcpy(buf[len .. len + comp.len], comp);
        len += comp.len;
    }
    buf[len] = 0;
    return buf[0..len];
}

/// Join the current process's cwd with `path` (if relative) and normalize.
/// Returns a null-terminated slice into `buf`, or null on error.
fn toAbsPath(path: []const u8, buf: *[512]u8) ?[]const u8 {
    if (path.len == 0) return null;
    if (path[0] == '/') return normPath(path, buf);
    const cwd = process.cwdSlice(process.current());

    var tmp: [512]u8 = undefined;
    const jlen = cwd.len + 1 + path.len;
    if (jlen >= tmp.len) return null;
    @memcpy(tmp[0..cwd.len], cwd);
    tmp[cwd.len] = '/';
    @memcpy(tmp[cwd.len + 1 .. cwd.len + 1 + path.len], path);
    return normPath(tmp[0..jlen], buf);
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
    var pbuf: [512]u8 = undefined;
    const path = toAbsPath(cstr(path_ptr), &pbuf) orelse return -EINVAL;
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
    if (fd > 2) {
        const f = &fds[fd];
        // Decrement the write-end reference count so readers see EOF when all
        // write ends are closed.
        if (f.is_write_pipe) {
            if (f.node.pipe) |p| {
                if (p.writers > 0) p.writers -= 1;
            }
        }
        f.used = false;
    }
    return 0;
}

fn sysPipe(fds_ptr: usize) isize {
    const ends = vfs.mkpipe() catch return -ENOMEM;
    const fds = fdTable();
    const rfd = allocFd() orelse return -EBADF;
    fds[rfd] = .{ .node = ends[0], .used = true };
    const wfd = allocFd() orelse { fds[rfd].used = false; return -EBADF; };
    fds[wfd] = .{ .node = ends[1], .used = true, .is_write_pipe = true };
    const out: *[2]u32 = @ptrFromInt(fds_ptr);
    out[0] = @intCast(rfd);
    out[1] = @intCast(wfd);
    return 0;
}

fn sysDup2(old_fd: usize, new_fd: usize) isize {
    const fds = fdTable();
    if (old_fd >= process.MAX_FD or !fds[old_fd].used) return -EBADF;
    if (new_fd >= process.MAX_FD) return -EBADF;
    // Close new_fd if open.
    if (fds[new_fd].used and new_fd != old_fd) {
        if (fds[new_fd].is_write_pipe) {
            if (fds[new_fd].node.pipe) |p| { if (p.writers > 0) p.writers -= 1; }
        }
    }
    fds[new_fd] = fds[old_fd];
    // If we just duplicated a write-end of a pipe, bump the writers count.
    if (fds[new_fd].is_write_pipe) {
        if (fds[new_fd].node.pipe) |p| p.writers += 1;
    }
    return @intCast(new_fd);
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
    var pbuf: [512]u8 = undefined;
    const path = toAbsPath(cstr(path_ptr), &pbuf) orelse return -EINVAL;
    _ = vfs.mkdir(path) catch |e| return errnoFor(e);
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
            .file, .pipe => DT_REG,
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
    var pbuf: [512]u8 = undefined;
    const path = toAbsPath(cstr(path_ptr), &pbuf) orelse return -EINVAL;
    const node = vfs.resolve(path) catch |e| return errnoFor(e);

    if (node.kind != .file) return -EINVAL;
    vfs.ensureLoaded(node);
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

/// chdir(): set the current working directory. Resolves relative paths.
fn sysChdir(path_ptr: usize) isize {
    const p = process.current();
    var pbuf: [512]u8 = undefined;
    const path = toAbsPath(cstr(path_ptr), &pbuf) orelse return -EINVAL;
    const node = vfs.resolve(path) catch return -ENOENT;
    if (node.kind != .dir) return -ENOTDIR;
    if (path.len > p.cwd.len - 1) return -ENAMETOOLONG;
    @memcpy(p.cwd[0..path.len], path);
    p.cwd_len = path.len;
    return 0;
}

/// getcwd(): copy the current working directory (null-terminated) into the
/// user buffer. Returns the length including the null byte, or negative errno.
fn sysGetcwd(buf_ptr: usize, size: usize) isize {
    const cwd = process.cwdSlice(process.current());
    if (cwd.len + 1 > size) return -ERANGE;
    const buf: [*]u8 = @ptrFromInt(buf_ptr);
    @memcpy(buf[0..cwd.len], cwd);
    buf[cwd.len] = 0;
    return @intCast(cwd.len + 1);
}


/// Central dispatcher, invoked from the SYSCALL handler with a saved trap frame.
/// Returns the value to place in the caller's rax (exit/execve do not return).
fn sysUnlink(path_ptr: usize) isize {
    var pbuf: [512]u8 = undefined;
    const path = toAbsPath(cstr(path_ptr), &pbuf) orelse return -EINVAL;
    vfs.unlink(path) catch |e| return errnoFor(e);
    return 0;
}

fn sysRename(old_ptr: usize, new_ptr: usize) isize {
    var obuf: [512]u8 = undefined;
    var nbuf: [512]u8 = undefined;
    const old_path = toAbsPath(cstr(old_ptr), &obuf) orelse return -EINVAL;
    const new_path = toAbsPath(cstr(new_ptr), &nbuf) orelse return -EINVAL;
    vfs.rename(old_path, new_path) catch |e| return errnoFor(e);
    return 0;
}

/// Sleep for `seconds` seconds by yielding to the scheduler until jiffies advances.
fn sysSleep(seconds: usize) isize {
    const target = pit.jiffies + @as(u64, seconds) * 100;
    while (pit.jiffies < target) sched.yield();
    return 0;
}

fn sysRmdir(path_ptr: usize) isize {
    var pbuf: [512]u8 = undefined;
    const path = toAbsPath(cstr(path_ptr), &pbuf) orelse return -EINVAL;
    vfs.rmdir(path) catch |e| return errnoFor(e);
    return 0;
}


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
        SYS_execve => blk: {
            var pbuf: [512]u8 = undefined;
            const path = toAbsPath(cstr(a1), &pbuf) orelse break :blk -EINVAL;
            break :blk process.exec(path, a2);
        },

        SYS_exit => process.exit(@bitCast(@as(u32, @truncate(a1)))),
        SYS_wait4 => process.wait4(@bitCast(a1), a2, a3),
        SYS_mkdir => sysMkdir(a1),
        SYS_pipe => sysPipe(a1),
        SYS_dup2 => sysDup2(a1, a2),
        SYS_getdents64 => sysGetdents64(a1, a2, a3),
        SYS_spawn => sysSpawn(a1, a2),
        SYS_getcwd => sysGetcwd(a1, a2),
        SYS_chdir => sysChdir(a1),
        SYS_uptime => @bitCast(pit.jiffies),
        SYS_unlink => sysUnlink(a1),
        SYS_rename => sysRename(a1, a2),
        SYS_sleep  => sysSleep(a1),
        SYS_rmdir  => sysRmdir(a1),
        else => -ENOSYS,
    };
}
