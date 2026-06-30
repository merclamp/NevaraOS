//! Process model: each user process owns an address space, a file-descriptor
//! table, a program break, and a kernel thread the scheduler time-slices. This
//! is what makes several user programs run at once. fork() deep-copies a running
//! process; execve() replaces the current image; wait4() reaps a zombie child.

const std = @import("std");
const sched = @import("sched.zig");
const vmm = @import("../mm/vmm.zig");
const heap = @import("../mm/heap.zig");
const vfs = @import("../fs/vfs.zig");
const elf = @import("../exec/elf.zig");
const usermode = @import("../arch/x86_64/usermode.zig");
const console = @import("../arch/x86_64/console.zig");
const signals = @import("signals.zig");

pub const MAX_FD = 64;

pub const File = struct {
    node: *vfs.Node = undefined,
    offset: usize = 0,
    used: bool = false,
    /// True for the write end of a pipe. We track this so we can decrement
    /// pipe.writers when every write-end fd is closed.
    is_write_pipe: bool = false,
};

const State = enum { unused, running, zombie };
const StartKind = enum { kernel, run_image, fork_resume };

pub const MAX_PROC = 64;
pub const MAX_ARGS = 16;
const ARG_LEN = 128;

pub const Process = struct {
    pid: u32 = 0,
    ppid: u32 = 0,
    state: State = .unused,
    cr3: usize = 0,
    thread: ?*sched.Thread = null,
    exit_code: i32 = 0,
    brk: usize = 0,
    // Bump pointer for anonymous mmap() regions (0 = not yet initialized).
    mmap_top: usize = 0,
    fds: [MAX_FD]File = .{File{}} ** MAX_FD,

    // Current working directory (absolute path, kernel-owned buffer).
    cwd: [256]u8 = [_]u8{'/'} ++ [_]u8{0} ** 255,
    cwd_len: usize = 1,
    // POSIX credentials.
    uid: u32 = 0,   // real user id
    gid: u32 = 0,   // real group id
    euid: u32 = 0,  // effective user id
    egid: u32 = 0,  // effective group id

    start: StartKind = .kernel,
    image: []const u8 = &.{},
    argv: [MAX_ARGS][ARG_LEN]u8 = undefined,
    arglen: [MAX_ARGS]usize = undefined,
    argc: usize = 0,
    fork_tf: usermode.TrapFrame = undefined,

    // Signals: pending bitmask, per-signal disposition (SIG_DFL/SIG_IGN/addr),
    // and the user restorer trampoline address (set on the first signal()).
    sig_pending: u32 = 0,
    sig_handlers: [32]u64 = [_]u64{0} ** 32,
    sig_restorer: u64 = 0,
};

var procs: [MAX_PROC]Process = .{Process{}} ** MAX_PROC;
var next_pid: u32 = 0;

fn allocProc() ?*Process {
    for (&procs) |*p| {
        if (p.state == .unused) return p;
    }
    return null;
}

/// Find a live process by pid (used by kill()).
pub fn byPid(pid: u32) ?*Process {
    for (&procs) |*p| {
        if (p.state != .unused and p.pid == pid) return p;
    }
    return null;
}

// ---- read-only views for procfs --------------------------------------------

/// The process-table slot at `i` (whether or not it is in use).
pub fn slot(i: usize) *Process { return &procs[i]; }

/// True if the slot holds a live (running or zombie) process.
pub fn isLive(p: *const Process) bool { return p.state != .unused; }

/// Single-letter process state, Linux /proc/<pid>/stat style.
pub fn stateChar(p: *const Process) u8 {
    return switch (p.state) {
        .running => 'R',
        .zombie  => 'Z',
        .unused  => 'X',
    };
}

/// The argv vector as slices (valid while the process lives).
pub fn argvSlices(p: *Process, out: *[MAX_ARGS][]const u8) []const []const u8 {
    return argSlices(p, out);
}

/// The process bound to the running kernel thread.
pub fn current() *Process {
    const t = sched.currentThread();
    for (&procs) |*p| {
        if (p.state != .unused and p.thread == t) return p;
    }
    return &procs[0]; // bootstrap/kernel process
}

/// Absolute path of the current working directory as a slice.
pub fn cwdSlice(self: *const Process) []const u8 {
    return self.cwd[0..self.cwd_len];
}


/// Register the kernel (kmain) context as the first process and set up stdio.
pub fn init() void {
    sched.init();

    const kp = &procs[0];
    kp.* = .{
        .pid = next_pid,
        .ppid = 0,
        .state = .running,
        .cr3 = vmm.currentCr3(),
        .thread = sched.currentThread(),
        .start = .kernel,
    };
    next_pid += 1;

    if (vfs.resolve("/dev/console")) |con| {
        for (0..3) |i| kp.fds[i] = .{ .node = con, .offset = 0, .used = true };
    } else |_| {}
}

fn copyArgs(p: *Process, args: []const []const u8) void {
    const n = @min(args.len, MAX_ARGS);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const len = @min(args[i].len, ARG_LEN - 1);
        @memcpy(p.argv[i][0..len], args[i][0..len]);
        p.arglen[i] = len;
    }
    p.argc = n;
}

fn argSlices(p: *Process, out: *[MAX_ARGS][]const u8) []const []const u8 {
    var i: usize = 0;
    while (i < p.argc) : (i += 1) out[i] = p.argv[i][0..p.arglen[i]];
    return out[0..p.argc];
}

/// Thread body for a freshly spawned/exec'd image.
fn imageEntry() noreturn {
    const p = current();
    vmm.switchTo(p.cr3);
    const entry = elf.load(p.image) orelse exit(-1);
    var buf: [MAX_ARGS][]const u8 = undefined;
    const args = argSlices(p, &buf);
    const sp = usermode.buildUserStack(args) orelse exit(-1);
    usermode.enter_user(entry, sp);
}

/// Thread body for a fork()ed child: resume at the parent's syscall site.
fn forkEntry() noreturn {
    const p = current();
    vmm.switchTo(p.cr3);
    usermode.user_return(&p.fork_tf);
}

/// Create a new process that runs `image` with `args`. Inherits the caller's fd
/// table. Returns the child pid, or -1 on failure. Does not wait.
pub fn spawnImage(image: []const u8, args: []const []const u8) i32 {
    const parent = current();
    const p = allocProc() orelse return -1;
    const cr3 = vmm.createAddressSpace() orelse return -1;

    p.* = .{
        .pid = next_pid,
        .ppid = parent.pid,
        .state = .running,
        .cr3 = cr3,
        .brk = 0,
        .fds = parent.fds,
        .cwd = parent.cwd,
        .cwd_len = parent.cwd_len,
        .uid = parent.uid,
        .gid = parent.gid,
        .euid = parent.euid,
        .egid = parent.egid,
        .start = .run_image,
        .image = image,
    };

    copyArgs(p, args);

    const t = sched.spawn(imageEntry) catch {
        vmm.freeUserSpace(cr3);
        p.state = .unused;
        return -1;
    };
    p.thread = t;
    t.cr3 = cr3;
    next_pid += 1;
    return @intCast(p.pid);
}

/// fork(): duplicate the current process. Returns the child pid in the parent;
/// the child resumes with rax=0 via its copied trap frame.
pub fn fork(tf: *const usermode.TrapFrame) isize {
    const parent = current();
    const p = allocProc() orelse return -1;
    const cr3 = vmm.forkAddressSpace(parent.cr3) orelse return -1;

    p.* = .{
        .pid = next_pid,
        .ppid = parent.pid,
        .state = .running,
        .cr3 = cr3,
        .brk = parent.brk,
        .mmap_top = parent.mmap_top, // inherited regions are cloned copy-on-write
        .fds = parent.fds,
        .cwd = parent.cwd,
        .cwd_len = parent.cwd_len,
        .uid = parent.uid,
        .gid = parent.gid,
        .euid = parent.euid,
        .egid = parent.egid,
        .start = .fork_resume,
    };
    // Bump the pipe writers count for every write-end fd inherited by the child.
    for (&p.fds) |*f| {
        if (f.used and f.is_write_pipe) {
            if (f.node.pipe) |pipe| pipe.writers += 1;
        }
    }
    // A child inherits the parent's signal dispositions; pending is cleared.
    p.sig_handlers = parent.sig_handlers;
    p.sig_restorer = parent.sig_restorer;
    p.fork_tf = tf.*;
    p.fork_tf.rax = 0;

    const t = sched.spawn(forkEntry) catch {
        vmm.freeUserSpace(cr3);
        p.state = .unused;
        return -1;
    };
    p.thread = t;
    t.cr3 = cr3;
    next_pid += 1;
    return @intCast(p.pid);
}

/// execve(): replace the current process image. argv strings are copied out of
/// the caller's address space before the old space is torn down. Returns a
/// negative errno only if the program can't be resolved; otherwise noreturn.
pub fn exec(path: []const u8, argv_ptr: usize) isize {
    const p = current();

    const node = vfs.resolve(path) catch return -2; // -ENOENT
    if (node.kind != .file) return -2;
    if (!vfs.mayAccess(node, p.euid, p.egid, vfs.X)) return -13; // -EACCES

    // Snapshot argv from the (still-current) address space.
    var tmp: [MAX_ARGS][ARG_LEN]u8 = undefined;
    var tlen: [MAX_ARGS]usize = undefined;
    var n: usize = 0;
    if (argv_ptr != 0) {
        const argv: [*]const usize = @ptrFromInt(argv_ptr);
        while (n < MAX_ARGS and argv[n] != 0) : (n += 1) {
            const s = std.mem.span(@as([*:0]const u8, @ptrFromInt(argv[n])));
            const len = @min(s.len, ARG_LEN - 1);
            @memcpy(tmp[n][0..len], s[0..len]);
            tlen[n] = len;
        }
    }

    vfs.ensureLoaded(node);
    const image = node.data[0..node.size];

    // Commit: swap to a fresh address space and discard the old one.
    // First, close-on-exec: release any pipe write-ends with fd >= 3 (they are
    // implicit close-on-exec so the reader eventually sees EOF).
    for (p.fds[3..]) |*f| {
        if (f.used and f.is_write_pipe) {
            if (f.node.pipe) |pipe| { if (pipe.writers > 0) pipe.writers -= 1; }
            f.used = false;
        }
    }
    const new_cr3 = vmm.createAddressSpace() orelse return -12; // -ENOMEM
    const old_cr3 = p.cr3;
    vmm.switchTo(new_cr3);
    p.cr3 = new_cr3;
    if (p.thread) |t| t.cr3 = new_cr3;
    p.brk = 0;
    p.mmap_top = 0; // fresh address space — no mmap regions yet
    // execve resets caught signals to default and forgets the old restorer.
    p.sig_handlers = [_]u64{0} ** 32;
    p.sig_restorer = 0;
    p.sig_pending = 0;
    vmm.freeUserSpace(old_cr3);

    const entry = elf.load(image) orelse exit(127);

    var buf: [MAX_ARGS][]const u8 = undefined;
    var i: usize = 0;
    while (i < n) : (i += 1) buf[i] = tmp[i][0..tlen[i]];
    copyArgs(p, buf[0..n]); // record argv for /proc/<pid>/{status,cmdline}
    const sp = usermode.buildUserStack(buf[0..n]) orelse exit(127);

    usermode.enter_user(entry, sp);
}

/// exit(): record the status, become a zombie, and stop running. The parent
/// reaps the remaining resources in wait4().
pub fn exit(code: i32) noreturn {
    const p = current();
    // Close all file descriptors so pipe write-ends are properly released.
    for (&p.fds) |*f| {
        if (!f.used) continue;
        if (f.is_write_pipe) {
            if (f.node.pipe) |pipe| { if (pipe.writers > 0) pipe.writers -= 1; }
        }
        f.used = false;
    }
    p.exit_code = code;
    p.state = .zombie;
    vmm.switchTo(vmm.kernelCr3()); // stop using our soon-to-be-freed tables
    sched.exitThread();
}

const WNOHANG: usize = 1;

/// wait4(): reap a child. `pid` > 0 waits for that child; <= 0 for any. With
/// WNOHANG, returns 0 immediately if no child has exited yet. Writes a
/// Linux-style status word to `status_ptr`. Returns the reaped pid, 0
/// (WNOHANG, none ready), or -10 (ECHILD).
pub fn wait4(pid: isize, status_ptr: usize, options: usize) isize {
    const me = current();
    while (true) {
        var has_child = false;
        for (&procs) |*c| {
            if (c.state == .unused or c.ppid != me.pid) continue;
            if (pid > 0 and c.pid != @as(u32, @intCast(pid))) continue;
            has_child = true;
            if (c.state == .zombie) {
                const cpid = c.pid;
                if (status_ptr != 0) {
                    const st: u32 = (@as(u32, @bitCast(@as(i32, c.exit_code))) & 0xFF) << 8;
                    @as(*u32, @ptrFromInt(status_ptr)).* = st;
                }
                vmm.freeUserSpace(c.cr3);
                if (c.thread) |t| sched.destroyThread(t);
                c.* = .{};
                return @intCast(cpid);
            }
        }
        if (!has_child) return -10; // ECHILD
        if (options & WNOHANG != 0) return 0;
        signals.checkBlocked(); // a terminating signal aborts the wait
        sched.yield(); // let the child make progress
    }
}
