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
const SYS_getdents64: usize = 217;
const SYS_spawn: usize = 1000;
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

// Userspace program break (single task for now). The heap sits between the ELF
// segments (64 TiB base) and the user stack region.
const USER_HEAP_BASE: usize = 0x4000_1000_0000;
var user_brk: usize = 0;

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

/// spawn(path, argv): load an ELF from the VFS and run it as an isolated child
/// process. argv strings (in the caller's address space) are copied into kernel
/// memory before the address-space switch. Returns the child's exit code.
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

    const code = usermode.spawnImage(image, args[0..n]);

    var i: usize = 0;
    while (i < n) : (i += 1) a.free(bufs[i]);
    return code;
}

// Linux dirent type values.
const DT_CHR: u8 = 2;
const DT_DIR: u8 = 4;
const DT_REG: u8 = 8;

inline fn alignUp8(v: usize) usize {
    return (v + 7) & ~@as(usize, 7);
}

/// getdents64(fd, buf, count): fill `buf` with linux_dirent64 records for the
/// directory. The fd offset tracks the next child index. Returns bytes written,
/// 0 at end of directory.
fn sysGetdents64(fd: usize, buf_ptr: usize, count: usize) isize {
    if (fd >= MAX_FD or !fds[fd].used) return -EBADF;
    const f = &fds[fd];
    const dir = f.node;
    if (dir.kind != .dir) return -ENOTDIR;

    const out: [*]u8 = @ptrFromInt(buf_ptr);
    var written: usize = 0;

    while (vfs.readdir(dir, f.offset)) |child| {
        // linux_dirent64: u64 d_ino, i64 d_off, u16 d_reclen, u8 d_type, name\0
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
/// user pages; returns the (new) break, or the current break on failure.
fn sysBrk(addr: usize) isize {
    if (user_brk == 0) user_brk = USER_HEAP_BASE;
    if (addr == 0 or addr < USER_HEAP_BASE) return @intCast(user_brk);

    const flags = vmm.PRESENT | vmm.WRITABLE | vmm.USER;
    var page = (user_brk + 0xFFF) & ~@as(usize, 0xFFF);
    while (page < addr) : (page += 0x1000) {
        if (vmm.walk(page) == null) {
            const frame = pmm.alloc() orelse return @intCast(user_brk);
            if (!vmm.map(page, frame, flags)) return @intCast(user_brk);
            @memset(@as([*]u8, @ptrFromInt(page))[0..0x1000], 0);
        }
    }
    user_brk = addr;
    return @intCast(addr);
}

/// Reset the program break (call when starting a fresh user program).
pub fn resetBrk() void {
    user_brk = 0;
}

/// Central dispatcher: invoked with Linux-style register arguments.
pub fn dispatch(num: usize, a1: usize, a2: usize, a3: usize) isize {
    return switch (num) {
        SYS_read => sysRead(a1, a2, a3),
        SYS_write => sysWrite(a1, a2, a3),
        SYS_open => sysOpen(a1, a2),
        SYS_close => sysClose(a1),
        SYS_lseek => sysLseek(a1, a2, a3),
        SYS_brk => sysBrk(a1),
        SYS_getpid => @intCast(sched.currentThread().id),
        SYS_exit => 0, // no userspace yet; nothing to tear down
        SYS_mkdir => sysMkdir(a1),
        SYS_getdents64 => sysGetdents64(a1, a2, a3),
        SYS_spawn => sysSpawn(a1, a2),
        else => -ENOSYS,
    };
}
