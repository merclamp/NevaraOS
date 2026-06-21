//! nstd — Nevara's native userspace runtime for Zig programs.
//!
//! A thin layer over the kernel syscall ABI: no C library involved. Provides
//! `_start`, raw syscalls, simple console I/O, and a brk-backed allocator. A
//! program just defines `pub fn main() void` and imports this module.

const std = @import("std");

// Linux x86_64 syscall numbers.
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
const SYS_getcwd: usize = 79;
const SYS_chdir: usize = 80;
const SYS_uptime: usize = 1001;
const SYS_unlink: usize = 87;
const SYS_rename: usize = 82;
const SYS_sleep:  usize = 1002;
const SYS_rmdir:  usize = 84;
const SYS_chmod:   usize = 90;
const SYS_getuid:  usize = 102;
const SYS_getgid:  usize = 104;
const SYS_setuid:  usize = 105;
const SYS_setgid:  usize = 106;
const SYS_geteuid: usize = 107;
const SYS_getegid: usize = 108;
const SYS_useradd: usize = 1003;
const SYS_userdel: usize = 1004;
const SYS_getpwnam: usize = 1005;
const SYS_net_ping: usize = 1010;
const SYS_net_send: usize = 1011;
const SYS_net_recv: usize = 1012;
const SYS_net_info: usize = 1013;
const SYS_tty_mode: usize = 1020;




inline fn syscall1(n: usize, a1: usize) usize {
    return asm volatile ("syscall"
        : [ret] "={rax}" (-> usize),
        : [n] "{rax}" (n),
          [a1] "{rdi}" (a1),
        : .{ .rcx = true, .r11 = true, .memory = true });
}

inline fn syscall3(n: usize, a1: usize, a2: usize, a3: usize) usize {
    return asm volatile ("syscall"
        : [ret] "={rax}" (-> usize),
        : [n] "{rax}" (n),
          [a1] "{rdi}" (a1),
          [a2] "{rsi}" (a2),
          [a3] "{rdx}" (a3),
        : .{ .rcx = true, .r11 = true, .memory = true });
}

// ---- Raw syscall wrappers ---------------------------------------------------

pub fn write(fd: usize, buf: []const u8) usize {
    return syscall3(SYS_write, fd, @intFromPtr(buf.ptr), buf.len);
}

pub fn read(fd: usize, buf: []u8) usize {
    return syscall3(SYS_read, fd, @intFromPtr(buf.ptr), buf.len);
}

pub fn open(path: [*:0]const u8, flags: usize) isize {
    return @bitCast(syscall3(SYS_open, @intFromPtr(path), flags, 0));
}

pub fn close(fd: usize) void {
    _ = syscall1(SYS_close, fd);
}

/// lseek(): reposition a file-descriptor offset.
/// whence: 0=SEEK_SET, 1=SEEK_CUR, 2=SEEK_END. Returns new offset or negative errno.
pub fn lseek(fd: usize, offset: isize, whence: usize) isize {
    return @bitCast(syscall3(SYS_lseek, fd, @bitCast(offset), whence));
}

pub fn getdents64(fd: usize, buf: []u8) isize {
    return @bitCast(syscall3(SYS_getdents64, fd, @intFromPtr(buf.ptr), buf.len));
}

/// Spawn an isolated child process from `path` with the given argv (a
/// null-terminated array of C strings). Returns its exit code.
pub fn spawn(path: [*:0]const u8, argv: [*]const ?[*:0]const u8) isize {
    return @bitCast(syscall3(SYS_spawn, @intFromPtr(path), @intFromPtr(argv), 0));
}

/// fork(): returns the child pid in the parent, 0 in the child, -1 on error.
pub fn fork() isize {
    return @bitCast(asm volatile ("syscall"
        : [ret] "={rax}" (-> usize),
        : [n] "{rax}" (@as(usize, 57)),
        : .{ .rcx = true, .r11 = true, .memory = true }));
}

/// execve(): replace the current image. Only returns (negative) on failure.
pub fn execve(path: [*:0]const u8, argv: [*]const ?[*:0]const u8) isize {
    return @bitCast(syscall3(59, @intFromPtr(path), @intFromPtr(argv), 0));
}

/// waitpid(): reap a child. `options` bit 0 = WNOHANG. Returns the reaped pid,
/// 0 (WNOHANG, none ready), or negative on error.
pub fn waitpid(pid: isize, status: *u32, options: usize) isize {
    return @bitCast(syscall3(61, @bitCast(pid), @intFromPtr(status), options));
}

/// mkdir(): create a directory. Returns 0 on success, negative on error.
pub fn mkdir(path: [*:0]const u8) isize {
    return @bitCast(syscall1(83, @intFromPtr(path)));
}

/// chdir(): change working directory. Returns 0 on success, negative errno.
pub fn chdir(path: [*:0]const u8) isize {
    return @bitCast(syscall1(SYS_chdir, @intFromPtr(path)));
}

/// getcwd(): copy current working directory into buf.
/// Returns string length including null terminator on success, negative on error.
pub fn getcwd(buf: []u8) isize {
    return @bitCast(syscall3(SYS_getcwd, @intFromPtr(buf.ptr), buf.len, 0));
}
/// unlink(): remove a file. Returns 0 on success, negative errno on failure.
pub fn unlinkFile(path: [*:0]const u8) isize {
    return @bitCast(syscall1(SYS_unlink, @intFromPtr(path)));
}

/// rmdir(): remove an empty directory. Returns 0 on success, negative errno.
pub fn rmdirPath(path: [*:0]const u8) isize {
    return @bitCast(syscall1(SYS_rmdir, @intFromPtr(path)));
}

/// rename(): rename/move a file or directory. Returns 0 on success.
pub fn renameFile(old: [*:0]const u8, new: [*:0]const u8) isize {
    return @bitCast(syscall3(SYS_rename, @intFromPtr(old), @intFromPtr(new), 0));
}

/// chmod(): change file permissions. Returns 0 on success, negative errno.
pub fn chmodFile(path: [*:0]const u8, mode: usize) isize {
    return @bitCast(syscall3(SYS_chmod, @intFromPtr(path), mode, 0));
}
/// getuid(): real user id of the current process.
pub fn getuid() u32 { return @truncate(syscall1(SYS_getuid, 0)); }

/// getgid(): real group id of the current process.
pub fn getgid() u32 { return @truncate(syscall1(SYS_getgid, 0)); }

/// geteuid(): effective user id.
pub fn geteuid() u32 { return @truncate(syscall1(SYS_geteuid, 0)); }

/// getegid(): effective group id.
pub fn getegid() u32 { return @truncate(syscall1(SYS_getegid, 0)); }

/// setuid(): set real and effective uid. Returns 0 or negative errno.
pub fn setuid(uid: u32) isize {
    return @bitCast(syscall1(SYS_setuid, uid));
}

/// setgid(): set real and effective gid. Returns 0 or negative errno.
pub fn setgid(gid: u32) isize {
    return @bitCast(syscall1(SYS_setgid, gid));
}

/// useradd(name, home, shell): create a new user. Root only. Returns uid or -errno.
pub fn useradd(name: [*:0]const u8, home: [*:0]const u8, shell: [*:0]const u8) isize {
    return @bitCast(syscall3(SYS_useradd, @intFromPtr(name), @intFromPtr(home), @intFromPtr(shell)));
}

/// userdel(name): remove a user. Root only. Returns 0 or -errno.
pub fn userdel(name: [*:0]const u8) isize {
    return @bitCast(syscall1(SYS_userdel, @intFromPtr(name)));
}

/// getpwnam(name, buf, len): write "name:x:uid:gid::home:shell\0" into buf. Returns 0 or -errno.
pub fn getpwnam(name: [*:0]const u8, buf: []u8) isize {
    return @bitCast(syscall3(SYS_getpwnam, @intFromPtr(name), @intFromPtr(buf.ptr), buf.len));
}

// ---- Network syscall wrappers -----------------------------------------------

/// netPing(ip, timeout_ms): send ICMP echo to ip. Returns 0=ok, -1=timeout, -2=no arp.
pub fn netPing(ip: [4]u8, timeout_ms: usize) isize {
    var ip_copy = ip;
    return @bitCast(syscall3(SYS_net_ping, @intFromPtr(&ip_copy), timeout_ms, 0));
}

/// netSend(dst_ip, src_port, dst_port, data): send UDP datagram.
pub fn netSend(dst_ip: [4]u8, src_port: u16, dst_port: u16, data: []const u8) isize {
    var ip_copy = dst_ip;
    return @bitCast(asm volatile ("syscall"
        : [ret] "={rax}" (-> usize),
        : [n]  "{rax}" (SYS_net_send),
          [a1] "{rdi}" (@intFromPtr(&ip_copy)),
          [a2] "{rsi}" (@as(usize, src_port)),
          [a3] "{rdx}" (@as(usize, dst_port)),
          [a4] "{r10}" (@intFromPtr(data.ptr)),
          [a5] "{r8}"  (data.len),
        : .{ .rcx = true, .r11 = true, .memory = true }));
}

/// netRecv(buf, src_ip, src_port, dst_port): receive one UDP datagram. Returns bytes or 0.
pub fn netRecv(buf: []u8, src_ip: *[4]u8, src_port: *u16, dst_port: *u16) usize {
    return @truncate(@as(usize, @bitCast(asm volatile ("syscall"
        : [ret] "={rax}" (-> usize),
        : [n]  "{rax}" (SYS_net_recv),
          [a1] "{rdi}" (@intFromPtr(buf.ptr)),
          [a2] "{rsi}" (buf.len),
          [a3] "{rdx}" (@intFromPtr(src_ip)),
          [a4] "{r10}" (@intFromPtr(src_port)),
          [a5] "{r8}"  (@intFromPtr(dst_port)),
        : .{ .rcx = true, .r11 = true, .memory = true }))));
}

/// netInfo(buf): write IP address string into buf. Returns 0 or -1 (no net).
pub fn netInfo(buf: []u8) isize {
    return @bitCast(syscall3(SYS_net_info, @intFromPtr(buf.ptr), buf.len, 0));
}

/// ttyMode(1) switches stdin to raw (byte-by-byte, no echo); 0 restores canonical.
pub fn ttyMode(mode: usize) void { _ = syscall1(SYS_tty_mode, mode); }

/// sleep(): sleep for `seconds` seconds (yields to other processes).
pub fn sleep(seconds: usize) void {
    _ = syscall1(SYS_sleep, seconds);
}

/// uptimeTicks(): returns jiffies since boot (PIT at 100 Hz → divide by 100 for seconds).
pub fn uptimeTicks() u64 {
    return syscall1(SYS_uptime, 0);
}

/// pipe(fds): create a read/write fd pair. fds[0]=read, fds[1]=write.
pub fn pipe(fds: *[2]u32) isize {
    return @bitCast(syscall1(22, @intFromPtr(fds)));
}

/// dup2(oldfd, newfd): duplicate oldfd to newfd, closing newfd first.
pub fn dup2(oldfd: usize, newfd: usize) isize {
    return @bitCast(syscall3(33, oldfd, newfd, 0));
}

/// A null-terminated C string as a Zig slice.
pub fn span(p: [*:0]const u8) []const u8 {
    var len: usize = 0;
    while (p[len] != 0) len += 1;
    return p[0..len];
}

pub fn getpid() usize {
    return asm volatile ("syscall"
        : [ret] "={rax}" (-> usize),
        : [n] "{rax}" (SYS_getpid),
        : .{ .rcx = true, .r11 = true, .memory = true });
}

pub fn exit(code: usize) noreturn {
    _ = syscall1(SYS_exit, code);
    unreachable;
}

fn brk(addr: usize) usize {
    return syscall1(SYS_brk, addr);
}

// ---- Console I/O ------------------------------------------------------------

pub fn print(s: []const u8) void {
    _ = write(1, s);
}

pub fn eprint(s: []const u8) void {
    _ = write(2, s);
}

pub fn printDec(value: u64) void {
    var buf: [20]u8 = undefined;
    if (value == 0) {
        print("0");
        return;
    }
    var i: usize = 0;
    var v = value;
    while (v > 0) : (v /= 10) {
        buf[i] = '0' + @as(u8, @intCast(v % 10));
        i += 1;
    }
    var j: usize = i;
    while (j > 0) {
        j -= 1;
        _ = write(1, buf[j .. j + 1]);
    }
}

// ---- Allocator (bump, grown via brk) ----------------------------------------

var heap_cur: usize = 0;
var heap_end: usize = 0;

inline fn alignUp(v: usize, a: usize) usize {
    return (v + a - 1) & ~(a - 1);
}

fn allocImpl(_: *anyopaque, len: usize, alignment: std.mem.Alignment, _: usize) ?[*]u8 {
    if (heap_cur == 0) {
        heap_cur = brk(0);
        heap_end = heap_cur;
    }
    const a = alignment.toByteUnits();
    const base = alignUp(heap_cur, a);
    const end = base + len;
    if (end > heap_end) {
        const want = alignUp(end, 0x1000);
        const got = brk(want);
        if (got < end) return null;
        heap_end = got;
    }
    heap_cur = end;
    return @ptrFromInt(base);
}

fn resizeImpl(_: *anyopaque, m: []u8, _: std.mem.Alignment, new_len: usize, _: usize) bool {
    return new_len <= m.len;
}

fn remapImpl(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize, _: usize) ?[*]u8 {
    return null;
}

fn freeImpl(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize) void {}

const vtable = std.mem.Allocator.VTable{
    .alloc = allocImpl,
    .resize = resizeImpl,
    .remap = remapImpl,
    .free = freeImpl,
};

/// A simple arena-style allocator (bump; free is a no-op).
pub fn allocator() std.mem.Allocator {
    return .{ .ptr = undefined, .vtable = &vtable };
}

// ---- Freestanding C mem builtins (the compiler may emit calls to these) ------

export fn memcpy(noalias d: [*]u8, noalias s: [*]const u8, n: usize) callconv(.c) [*]u8 {
    var i: usize = 0;
    while (i < n) : (i += 1) d[i] = s[i];
    return d;
}
export fn memset(d: [*]u8, c: c_int, n: usize) callconv(.c) [*]u8 {
    const b: u8 = @truncate(@as(c_uint, @bitCast(c)));
    var i: usize = 0;
    while (i < n) : (i += 1) d[i] = b;
    return d;
}

export fn strlen(s: [*:0]const u8) callconv(.c) usize {
    var i: usize = 0;
    while (s[i] != 0) : (i += 1) {
        asm volatile ("" ::: .{ .memory = true }); // stop the strlen-idiom fold
    }
    return i;
}

// ---- Entry point + arguments ------------------------------------------------

var g_argc: usize = 0;
var g_argv: [*]const ?[*:0]const u8 = undefined;

/// Number of command-line arguments.
pub fn argc() usize {
    return g_argc;
}

/// Argument `i` as a slice, or null if out of range.
pub fn arg(i: usize) ?[]const u8 {
    if (i >= g_argc) return null;
    const p = g_argv[i] orelse return null;
    var len: usize = 0;
    while (p[len] != 0) len += 1;
    return p[0..len];
}

/// Argument `i` as a null-terminated C pointer (for `open`), or null.
pub fn argZ(i: usize) ?[*:0]const u8 {
    if (i >= g_argc) return null;
    return g_argv[i];
}

/// Runtime entry: a program's naked `_start` reads argc/argv off the stack and
/// tail-calls this. It records the arguments, runs `main`, and exits.
///     export fn _start() callconv(.naked) noreturn {
///         asm volatile ("mov (%rsp),%rdi; lea 8(%rsp),%rsi; call startMain");
///     }
///     export fn startMain(c: usize, v: [*]const ?[*:0]const u8) callconv(.c) noreturn {
///         nstd.start(c, v);
///     }
pub fn start(c: usize, v: [*]const ?[*:0]const u8) noreturn {
    g_argc = c;
    g_argv = v;
    @import("root").main();
    exit(0);
}
