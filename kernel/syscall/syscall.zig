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
const users = @import("../proc/users.zig");
const net     = @import("../net/net.zig");
const rtl8139 = @import("../net/rtl8139.zig");
const tty     = @import("../tty.zig");
const signals = @import("../proc/signals.zig");


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
const SYS_kill: usize = 62;
const SYS_signal: usize = 48;
const SYS_sigreturn: usize = 1007;
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
const SYS_chmod:  usize = 90;
const SYS_fchmod: usize = 91;
const SYS_chown:  usize = 92;
const SYS_statp:  usize = 1030; // stat(path, *NevStat) — Nevara-specific compact stat
const SYS_getuid:  usize = 102;
const SYS_getgid:  usize = 104;
const SYS_setuid:  usize = 105;
const SYS_setgid:  usize = 106;
const SYS_geteuid: usize = 107;
const SYS_getegid: usize = 108;
const SYS_useradd: usize = 1003;
const SYS_userdel: usize = 1004;
const SYS_getpwnam:  usize = 1005;
const SYS_reboot:    usize = 1006; // reboot(mode): 0=poweroff, 1=reboot. Root only.
const SYS_net_ping:  usize = 1010; // ping(ip_ptr, timeout_ms) -> 0=ok, -1=timeout
const SYS_net_send:  usize = 1011; // udpSend(dst_ip_ptr, sport, dport, buf_ptr, len)
const SYS_net_recv:  usize = 1012; // udpRecv(buf_ptr, len, src_ip_ptr, sport_ptr, dport_ptr)
const SYS_net_info:  usize = 1013;
// TCP socket syscalls (1014-1020 range)
const SYS_tcp_open:    usize = 1014; // () -> sock_idx or -1
const SYS_tcp_connect: usize = 1015; // (sock, ip_ptr, port, src_port) -> 0 ok/-1
const SYS_tcp_listen:  usize = 1016; // (sock, port) -> 0 ok/-1
const SYS_tcp_accept:  usize = 1017; // (listen_sock) -> new_sock or -1
const SYS_tcp_send:    usize = 1018; // (sock, buf_ptr, len) -> bytes sent
const SYS_tcp_recv:    usize = 1019; // (sock, buf_ptr, len) -> bytes or 0
const SYS_tcp_close:   usize = 1021; // (sock) -> 0
const SYS_tcp_status:  usize = 1022; // (sock) -> 0=connected,1=listen,2=closed,3=data
const SYS_tty_mode:    usize = 1020;




// errno values (returned negated).
const EPERM: isize = 1;
const ENOENT: isize = 2;
const ESRCH: isize = 3;
const EBADF: isize = 9;
const ECHILD: isize = 10;
const EACCES: isize = 13;
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
    var created = false;
    const node = vfs.resolve(path) catch |e| blk: {
        if (e == error.NotFound and (flags & O_CREAT) != 0) {
            const n = vfs.create(path, .file) catch |ce| return errnoFor(ce);
            // A new file belongs to its creator.
            const me = process.current();
            vfs.setOwner(n, me.euid, me.egid);
            created = true;
            break :blk n;
        }
        return errnoFor(e);
    };
    // DAC: an existing file must grant the requested access. A just-created file
    // is implicitly accessible to its creator (POSIX skips the check on O_CREAT).
    if (!created) {
        const me = process.current();
        var want: u8 = 0;
        const acc = flags & 0o3; // O_RDONLY=0, O_WRONLY=1, O_RDWR=2
        if (acc == 0 or acc == 2) want |= vfs.R;
        if (acc == 1 or acc == 2) want |= vfs.W;
        if (!vfs.mayAccess(node, me.euid, me.egid, want)) return -EACCES;
    }
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
    const node = vfs.mkdir(path) catch |e| return errnoFor(e);
    const me = process.current();
    vfs.setOwner(node, me.euid, me.egid);
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
    const me = process.current();
    if (!vfs.mayAccess(node, me.euid, me.egid, vfs.X)) return -EACCES;
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



// ---- Net syscalls ----------------------------------------------------------

// SYS_net_ping(ip_ptr, timeout_ms) -> 0 ok, -1 timeout, -2 no arp
fn sysNetPing(ip_ptr: usize, timeout_ms: usize) isize {
    const ip: *const [4]u8 = @ptrFromInt(ip_ptr);
    const r = net.ping(ip.*, timeout_ms);
    return switch (r) {
        .ok                  => 0,
        .timeout             => -1,
        .unreachable_no_arp  => -2,
    };
}

// SYS_net_send(dst_ip_ptr, sport, dport, buf_ptr, len)
fn sysNetSend(ip_ptr: usize, sport: usize, dport: usize, buf_ptr: usize, len: usize) isize {
    const ip: *const [4]u8 = @ptrFromInt(ip_ptr);
    const buf: [*]const u8 = @ptrFromInt(buf_ptr);
    net.udpSend(ip.*, @intCast(sport), @intCast(dport), buf[0..len]);
    return 0;
}

// SYS_net_recv(buf_ptr, len, src_ip_ptr, sport_ptr, dport_ptr) -> bytes read or 0
fn sysNetRecv(buf_ptr: usize, len: usize, src_ip_ptr: usize, sport_ptr: usize, dport_ptr: usize) isize {
    const buf: [*]u8 = @ptrFromInt(buf_ptr);
    var src_ip: [4]u8 = .{0} ** 4;
    var src_port: u16 = 0;
    var dst_port: u16 = 0;
    const n = net.udpRecv(buf[0..len], &src_ip, &src_port, &dst_port);
    if (n > 0 and src_ip_ptr != 0) {
        const ip_out: *[4]u8 = @ptrFromInt(src_ip_ptr);
        ip_out.* = src_ip;
    }
    if (sport_ptr != 0) @as(*u16, @ptrFromInt(sport_ptr)).* = src_port;
    if (dport_ptr != 0) @as(*u16, @ptrFromInt(dport_ptr)).* = dst_port;
    return @intCast(n);
}

// SYS_net_info(buf_ptr, len) -> 0 ok, -1 no net
fn sysNetInfo(buf_ptr: usize, len: usize) isize {
    if (!net.isReady()) return -1;
    const buf: [*]u8 = @ptrFromInt(buf_ptr);
    // Write 10.0.2.15 + NUL
    const info = "10.0.2.15";
    const n = @min(info.len, len - 1);
    @memcpy(buf[0..n], info[0..n]);
    buf[n] = 0;
    return 0;
}


fn sysTtyMode(mode: usize) isize { tty.raw_mode = (mode != 0); return 0; }

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
    while (pit.jiffies < target) {
        signals.checkBlocked(); // a terminating signal cuts the sleep short
        sched.yield();
    }
    return 0;
}

fn sysRmdir(path_ptr: usize) isize {
    var pbuf: [512]u8 = undefined;
    const path = toAbsPath(cstr(path_ptr), &pbuf) orelse return -EINVAL;
    vfs.rmdir(path) catch |e| return errnoFor(e);
    return 0;
}


// Only the file's owner (or root) may change its mode / owner.
fn ownsOrRoot(node: *const vfs.Node) bool {
    const me = process.current();
    return me.euid == 0 or me.euid == node.uid;
}

fn sysChmod(path_ptr: usize, mode: usize) isize {
    var pbuf: [512]u8 = undefined;
    const path = toAbsPath(cstr(path_ptr), &pbuf) orelse return -EINVAL;
    const node = vfs.resolve(path) catch |e| return errnoFor(e);
    if (!ownsOrRoot(node)) return -EPERM;
    vfs.applyChmod(node, @intCast(mode & 0xFFF)) catch |e| return errnoFor(e);
    return 0;
}

fn sysFchmod(fd: usize, mode: usize) isize {
    const fds = fdTable();
    if (fd >= process.MAX_FD or !fds[fd].used) return -EBADF;
    const node = fds[fd].node;
    if (!ownsOrRoot(node)) return -EPERM;
    vfs.applyChmod(node, @intCast(mode & 0xFFF)) catch |e| return errnoFor(e);
    return 0;
}

// chown(path, uid, gid): only root may change ownership (a uid/gid of (u32)-1
// leaves that field unchanged).
fn sysChown(path_ptr: usize, uid: usize, gid: usize) isize {
    if (process.current().euid != 0) return -EPERM;
    var pbuf: [512]u8 = undefined;
    const path = toAbsPath(cstr(path_ptr), &pbuf) orelse return -EINVAL;
    const node = vfs.resolve(path) catch |e| return errnoFor(e);
    vfs.applyChown(node, @truncate(uid), @truncate(gid)) catch |e| return errnoFor(e);
    return 0;
}

// stat(path, *NevStat): compact 16-byte stat — mode(u32) uid(u32) gid(u32) size(u32).
fn sysStatp(path_ptr: usize, out_ptr: usize) isize {
    var pbuf: [512]u8 = undefined;
    const path = toAbsPath(cstr(path_ptr), &pbuf) orelse return -EINVAL;
    const node = vfs.resolve(path) catch |e| return errnoFor(e);
    if (out_ptr == 0) return -EINVAL;
    const out: [*]u32 = @ptrFromInt(out_ptr);
    out[0] = vfs.getMode(node);
    out[1] = node.uid;
    out[2] = node.gid;
    out[3] = @intCast(node.size);
    return 0;
}
fn sysGetuid()  isize { return @intCast(process.current().uid); }
fn sysGetgid()  isize { return @intCast(process.current().gid); }
fn sysGeteuid() isize { return @intCast(process.current().euid); }
fn sysGetegid() isize { return @intCast(process.current().egid); }

fn sysSetuid(uid: usize) isize {
    const p = process.current();
    if (p.euid != 0 and uid != p.uid) return -EPERM;
    p.uid = @intCast(uid);
    p.euid = @intCast(uid);
    return 0;
}

fn sysSetgid(gid: usize) isize {
    const p = process.current();
    if (p.euid != 0 and gid != p.gid) return -EPERM;
    p.gid = @intCast(gid);
    p.egid = @intCast(gid);
    return 0;
}

// SYS_useradd(name_ptr, home_ptr, shell_ptr) -> uid or -errno
fn sysUseradd(name_ptr: usize, home_ptr: usize, shell_ptr: usize) isize {
    if (process.current().euid != 0) return -EPERM;
    return users.add(cstr(name_ptr), cstr(home_ptr), cstr(shell_ptr));
}

// SYS_userdel(name_ptr) -> 0 or -errno
fn sysUserdel(name_ptr: usize) isize {
    if (process.current().euid != 0) return -EPERM;
    return if (users.remove(cstr(name_ptr))) 0 else -ENOENT;
}

inline fn outb(port: u16, value: u8) void {
    asm volatile ("outb %[v], %[p]"
        :
        : [v] "{al}" (value),
          [p] "{dx}" (port),
    );
}

inline fn outw(port: u16, value: u16) void {
    asm volatile ("outw %[v], %[p]"
        :
        : [v] "{ax}" (value),
          [p] "{dx}" (port),
    );
}

// SYS_reboot(mode): 0 = power off, 1 = reboot. Root only. Does not return on
// success. We try the common QEMU/Bochs shutdown ports, then fall back to a
// triple fault (reboot) or a hard halt (poweroff) if the platform ignores us.
fn sysReboot(mode: usize) isize {
    if (process.current().euid != 0) return -EPERM;
    asm volatile ("cli");
    if (mode == 0) {
        // ACPI poweroff: QEMU (>= 2.0) listens on 0x604, older Bochs on 0xB004,
        // some configs on 0x600. Writing 0x2000 sets SLP_TYP=S5 + SLP_EN.
        outw(0x604, 0x2000);
        outw(0xB004, 0x2000);
        outw(0x600, 0x2000);
    } else {
        // Reboot: pulse the CPU reset line via the 8042 keyboard controller,
        // then fall back to the PCI reset control register (port 0xCF9), which
        // QEMU's i440fx/q35 chipsets honour.
        outb(0x64, 0xFE);
        outb(0xCF9, 0x02);
        outb(0xCF9, 0x06);
    }
    // If we get here the platform ignored the request; park the CPU.
    while (true) asm volatile ("hlt");
}

// SYS_kill(pid, sig) -> 0 or -errno. Posts `sig` to process `pid`.
fn sysKill(pid_raw: usize, sig: usize) isize {
    const pid: isize = @bitCast(pid_raw);
    if (sig >= signals.NSIG) return -EINVAL;
    if (pid <= 0) return -ESRCH; // process groups not supported yet
    const target = process.byPid(@intCast(pid)) orelse return -ESRCH;
    const me = process.current();
    if (me.euid != 0 and me.uid != target.uid) return -EPERM;
    if (sig == 0) return 0; // permission/existence probe
    signals.post(target, @intCast(sig));
    return 0;
}

// SYS_signal(sig, handler, restorer) -> previous disposition or -errno.
// handler is SIG_DFL(0), SIG_IGN(1), or a user function address; restorer is
// the address of the user sigreturn trampoline (recorded once per process).
fn sysSignal(sig: usize, handler: usize, restorer: usize) isize {
    if (sig == 0 or sig >= signals.NSIG or sig == signals.SIGKILL) return -EINVAL;
    const p = process.current();
    const prev = p.sig_handlers[sig];
    p.sig_handlers[sig] = handler;
    if (restorer != 0) p.sig_restorer = restorer;
    return @bitCast(prev);
}

// SYS_sigreturn: restore the trap frame saved when the handler was entered.
// The trampoline issues this with rsp pointing at the saved frame.
fn sysSigreturn(tf: *usermode.TrapFrame) isize {
    const saved: *const usermode.TrapFrame = @ptrFromInt(tf.rsp);
    tf.* = saved.*;
    return @bitCast(tf.rax); // preserve the interrupted syscall's result
}

/// Append s into buf[pos..limit-1], leaving room for a nul. Returns new pos.
fn appendBuf(buf: [*]u8, pos: usize, limit: usize, s: []const u8) usize {
    if (limit == 0 or pos + 1 >= limit) return pos;
    const avail = limit - pos - 1;
    const l = @min(s.len, avail);
    @memcpy(buf[pos .. pos + l], s[0..l]);
    return pos + l;
}

/// Format u32 as decimal into buf[10]. Returns slice of written digits.
fn fmtU32Dec(v: u32, buf: *[10]u8) []const u8 {
    if (v == 0) { buf[0] = '0'; return buf[0..1]; }
    var i: usize = buf.len;
    var n = v;
    while (n > 0) : (n /= 10) {
        i -= 1;
        buf[i] = '0' + @as(u8, @intCast(n % 10));
    }
    return buf[i..];
}

// SYS_getpwnam(name_ptr, buf_ptr, buf_len) -> 0 or -errno
// Writes "name:x:uid:gid::home:shell\0" into buf.
fn sysGetpwnam(name_ptr: usize, buf_ptr: usize, buf_len: usize) isize {
    const u = users.findByName(cstr(name_ptr)) orelse return -ENOENT;
    if (buf_len == 0) return -EINVAL;
    const buf: [*]u8 = @ptrFromInt(buf_ptr);
    var pos: usize = 0;
    pos = appendBuf(buf, pos, buf_len, u.nameslice());
    pos = appendBuf(buf, pos, buf_len, ":x:");
    var nbuf: [10]u8 = undefined;
    pos = appendBuf(buf, pos, buf_len, fmtU32Dec(u.uid, &nbuf));
    pos = appendBuf(buf, pos, buf_len, ":");
    var gbuf: [10]u8 = undefined;
    pos = appendBuf(buf, pos, buf_len, fmtU32Dec(u.gid, &gbuf));
    pos = appendBuf(buf, pos, buf_len, "::");
    pos = appendBuf(buf, pos, buf_len, u.homeslice());
    pos = appendBuf(buf, pos, buf_len, ":");
    pos = appendBuf(buf, pos, buf_len, u.shellslice());
    if (pos < buf_len) buf[pos] = 0;
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
        SYS_kill => sysKill(a1, a2),
        SYS_signal => sysSignal(a1, a2, a3),
        SYS_sigreturn => sysSigreturn(tf),
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
        SYS_chmod  => sysChmod(a1, a2),
        SYS_fchmod => sysFchmod(a1, a2),
        SYS_chown  => sysChown(a1, a2, a3),
        SYS_statp  => sysStatp(a1, a2),
        SYS_getuid   => sysGetuid(),
        SYS_getgid   => sysGetgid(),
        SYS_geteuid  => sysGeteuid(),
        SYS_getegid  => sysGetegid(),
        SYS_setuid   => sysSetuid(a1),
        SYS_setgid   => sysSetgid(a1),
        SYS_useradd  => sysUseradd(a1, a2, a3),
        SYS_userdel  => sysUserdel(a1),
        SYS_getpwnam => sysGetpwnam(a1, a2, a3),
        SYS_reboot   => sysReboot(a1),
        SYS_net_ping  => sysNetPing(a1, a2),
        SYS_net_send  => sysNetSend(a1, a2, a3, tf.r10, tf.r8),
        SYS_net_recv  => sysNetRecv(a1, a2, a3, tf.r10, tf.r8),
        SYS_net_info  => sysNetInfo(a1, a2),
        SYS_tcp_open    => sysTcpOpen(),
        SYS_tcp_connect => sysTcpConnect(a1, a2, a3, tf.r10),
        SYS_tcp_listen  => sysTcpListen(a1, a2),
        SYS_tcp_accept  => sysTcpAccept(a1),
        SYS_tcp_send    => sysTcpSend(a1, a2, a3),
        SYS_tcp_recv    => sysTcpRecv(a1, a2, a3),
        SYS_tcp_close   => sysTcpClose(a1),
        SYS_tcp_status  => sysTcpStatus(a1),
        SYS_tty_mode  => sysTtyMode(a1),
        else => -ENOSYS,
    };
}

// ---- TCP syscall implementations --------------------------------------------

fn sysTcpOpen() isize {
    const idx = net.tcp.allocSock();
    if (idx == 0xff) return -ENOMEM;
    return @intCast(idx);
}

fn sysTcpConnect(sock: usize, ip_ptr: usize, port: usize, src_port: usize) isize {
    const ip: *const [4]u8 = @ptrFromInt(ip_ptr);
    const ok = net.tcp.connect(
        @intCast(sock), ip.*, @intCast(port), @intCast(src_port),
    );
    if (!ok) return -EINVAL;
    // Poll until connected or timeout (~3s).
    var i: usize = 0;
    while (i < 3_000_000) : (i += 100) {
        rtl8139.pollRx();
        if (net.tcp.isConnected(@intCast(sock))) return 0;
        if (net.tcp.isClosed(@intCast(sock))) return -EINVAL;
    }
    return -EINVAL; // timeout
}

fn sysTcpListen(sock: usize, port: usize) isize {
    const ok = net.tcp.listen(@intCast(sock), @intCast(port));
    return if (ok) 0 else -EINVAL;
}

fn sysTcpAccept(listen_sock: usize) isize {
    // Non-blocking: return -EAGAIN if nothing ready.
    const idx = net.tcp.accept(@intCast(listen_sock));
    if (idx == 0xff) return -11; // EAGAIN
    return @intCast(idx);
}

fn sysTcpSend(sock: usize, buf_ptr: usize, len: usize) isize {
    const buf: [*]const u8 = @ptrFromInt(buf_ptr);
    const n = net.tcp.send(@intCast(sock), buf[0..len]);
    return @intCast(n);
}

fn sysTcpRecv(sock: usize, buf_ptr: usize, len: usize) isize {
    // Poll RX to process any incoming segments.
    rtl8139.pollRx();
    const buf: [*]u8 = @ptrFromInt(buf_ptr);
    const n = net.tcp.rbufRead(@intCast(sock), buf[0..len]);
    if (n == 0 and net.tcp.peerClosed(@intCast(sock))) return 0; // EOF
    return @intCast(n);
}

fn sysTcpClose(sock: usize) isize {
    net.tcp.close(@intCast(sock));
    return 0;
}

fn sysTcpStatus(sock: usize) isize {
    if (net.tcp.isConnected(@intCast(sock)))  return 0;
    if (net.tcp.isListening(@intCast(sock)))  return 1;
    if (net.tcp.isClosed(@intCast(sock)))     return 2;
    if (net.tcp.hasData(@intCast(sock)))      return 3;
    return 2;
}
