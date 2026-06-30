//! Synthetic /proc and /sys filesystems.
//!
//! These are pure in-RAM trees grafted onto the VFS at boot. Their files carry
//! no stored data: each read runs a generator that synthesizes current content
//! from live kernel state (the tick counter, the page allocator, the process
//! table, CPUID, ...). /proc additionally enumerates one directory per live
//! process via the VFS synthetic-directory hook, so `ls /proc` and
//! `cat /proc/<pid>/status` reflect the real process table.
//!
//! Everything here is read-only — writes return NotSupported.

const std = @import("std");
const vfs = @import("vfs.zig");
const process = @import("../proc/process.zig");
const pmm = @import("../mm/pmm.zig");
const pit = @import("../arch/x86_64/pit.zig");

// Identity strings, kept consistent with NevBox `uname`.
const OSTYPE = "Nevara";
const OSRELEASE = "0.1.0";
const KVERSION = "#1 SMP";
const HOSTNAME = "nevara";
const MACHINE = "x86_64";

// ---- tiny text builder ------------------------------------------------------

const Writer = struct {
    out: []u8,
    pos: usize = 0,

    fn str(self: *Writer, s: []const u8) void {
        if (self.pos >= self.out.len) return;
        const n = @min(s.len, self.out.len - self.pos);
        @memcpy(self.out[self.pos .. self.pos + n], s[0..n]);
        self.pos += n;
    }

    fn ch(self: *Writer, c: u8) void {
        if (self.pos < self.out.len) {
            self.out[self.pos] = c;
            self.pos += 1;
        }
    }

    fn dec(self: *Writer, v: u64) void {
        if (v == 0) {
            self.ch('0');
            return;
        }
        var tmp: [20]u8 = undefined;
        var i: usize = tmp.len;
        var n = v;
        while (n > 0) : (n /= 10) {
            i -= 1;
            tmp[i] = '0' + @as(u8, @intCast(n % 10));
        }
        self.str(tmp[i..]);
    }

    /// Two-digit zero-padded decimal (for sub-second fields).
    fn dec2(self: *Writer, v: u64) void {
        self.ch('0' + @as(u8, @intCast((v / 10) % 10)));
        self.ch('0' + @as(u8, @intCast(v % 10)));
    }
};

fn parseU32(s: []const u8) ?u32 {
    if (s.len == 0) return null;
    var v: u32 = 0;
    for (s) |c| {
        if (c < '0' or c > '9') return null;
        v = v * 10 + (c - '0');
    }
    return v;
}

// ---- CPUID ------------------------------------------------------------------

fn cpuid(leaf: u32, sub: u32) [4]u32 {
    var a: u32 = undefined;
    var b: u32 = undefined;
    var c: u32 = undefined;
    var d: u32 = undefined;
    asm volatile ("cpuid"
        : [a] "={eax}" (a),
          [b] "={ebx}" (b),
          [c] "={ecx}" (c),
          [d] "={edx}" (d),
        : [leaf] "{eax}" (leaf),
          [sub] "{ecx}" (sub),
    );
    return .{ a, b, c, d };
}

fn appendReg(w: *Writer, reg: u32) void {
    var i: usize = 0;
    while (i < 4) : (i += 1) {
        const byte: u8 = @truncate(reg >> @intCast(i * 8));
        if (byte == 0) continue;
        w.ch(byte);
    }
}

// ---- global /proc generators ------------------------------------------------

fn genVersion(_: *vfs.Node, out: []u8) usize {
    var w = Writer{ .out = out };
    w.str(OSTYPE);
    w.str(" version ");
    w.str(OSRELEASE);
    w.str(" (nevara@localhost) ");
    w.str(KVERSION);
    w.str(" ");
    w.str(MACHINE);
    w.ch('\n');
    return w.pos;
}

fn genUptime(_: *vfs.Node, out: []u8) usize {
    var w = Writer{ .out = out };
    const j = pit.jiffies; // 100 Hz
    const secs = j / 100;
    const cs = j % 100;
    // "uptime idle" — we have no idle accounting, so report it equal to uptime.
    w.dec(secs);
    w.ch('.');
    w.dec2(cs);
    w.ch(' ');
    w.dec(secs);
    w.ch('.');
    w.dec2(cs);
    w.ch('\n');
    return w.pos;
}

fn genMeminfo(_: *vfs.Node, out: []u8) usize {
    var w = Writer{ .out = out };
    const total_kb = pmm.totalFrames() * (pmm.PAGE_SIZE / 1024);
    const free_kb = pmm.freeFrames() * (pmm.PAGE_SIZE / 1024);
    const line = struct {
        fn emit(ww: *Writer, label: []const u8, kb: u64) void {
            ww.str(label);
            ww.str(":");
            // pad label column loosely; not byte-exact but readable
            ww.str("    ");
            ww.dec(kb);
            ww.str(" kB\n");
        }
    }.emit;
    line(&w, "MemTotal", total_kb);
    line(&w, "MemFree", free_kb);
    line(&w, "MemAvailable", free_kb);
    line(&w, "Buffers", 0);
    line(&w, "Cached", 0);
    line(&w, "SwapTotal", 0);
    line(&w, "SwapFree", 0);
    return w.pos;
}

fn genCpuinfo(_: *vfs.Node, out: []u8) usize {
    var w = Writer{ .out = out };
    const id = cpuid(0, 0);
    w.str("processor\t: 0\n");
    w.str("vendor_id\t: ");
    appendReg(&w, id[1]); // ebx
    appendReg(&w, id[3]); // edx
    appendReg(&w, id[2]); // ecx
    w.ch('\n');

    const ver = cpuid(1, 0);
    const eax = ver[0];
    const family = (eax >> 8) & 0xF;
    const model = (eax >> 4) & 0xF;
    const stepping = eax & 0xF;
    w.str("cpu family\t: ");
    w.dec(family);
    w.ch('\n');
    w.str("model\t\t: ");
    w.dec(model);
    w.ch('\n');
    w.str("stepping\t: ");
    w.dec(stepping);
    w.ch('\n');

    // Brand string from extended leaves, if available.
    const ext = cpuid(0x80000000, 0);
    if (ext[0] >= 0x80000004) {
        w.str("model name\t: ");
        var leaf: u32 = 0x80000002;
        while (leaf <= 0x80000004) : (leaf += 1) {
            const r = cpuid(leaf, 0);
            appendReg(&w, r[0]);
            appendReg(&w, r[1]);
            appendReg(&w, r[2]);
            appendReg(&w, r[3]);
        }
        w.ch('\n');
    }
    return w.pos;
}

fn liveCount() u64 {
    var n: u64 = 0;
    var i: usize = 0;
    while (i < process.MAX_PROC) : (i += 1) {
        if (process.isLive(process.slot(i))) n += 1;
    }
    return n;
}

fn genStat(_: *vfs.Node, out: []u8) usize {
    var w = Writer{ .out = out };
    const j = pit.jiffies;
    // Single CPU, mostly idle: put all jiffies in the idle column.
    w.str("cpu  0 0 0 ");
    w.dec(j);
    w.str(" 0 0 0 0 0 0\n");
    w.str("cpu0 0 0 0 ");
    w.dec(j);
    w.str(" 0 0 0 0 0 0\n");
    w.str("ctxt 0\n");
    w.str("btime 0\n");
    w.str("processes ");
    w.dec(liveCount());
    w.ch('\n');
    w.str("procs_running 1\n");
    w.str("procs_blocked 0\n");
    return w.pos;
}

fn genLoadavg(_: *vfs.Node, out: []u8) usize {
    var w = Writer{ .out = out };
    w.str("0.00 0.00 0.00 1/");
    w.dec(liveCount());
    w.str(" 0\n");
    return w.pos;
}

fn genFilesystems(_: *vfs.Node, out: []u8) usize {
    var w = Writer{ .out = out };
    w.str("nodev\ttmpfs\n");
    w.str("nodev\tproc\n");
    w.str("nodev\tsysfs\n");
    w.str("\text4\n");
    return w.pos;
}

fn genMounts(_: *vfs.Node, out: []u8) usize {
    var w = Writer{ .out = out };
    w.str("/dev/sda / ext4 rw 0 0\n");
    w.str("proc /proc proc rw 0 0\n");
    w.str("sysfs /sys sysfs rw 0 0\n");
    w.str("tmpfs /dev tmpfs rw 0 0\n");
    return w.pos;
}

fn genCmdline(_: *vfs.Node, out: []u8) usize {
    var w = Writer{ .out = out };
    w.str("BOOT_IMAGE=/boot/nevara root=/dev/sda rw\n");
    return w.pos;
}

// ---- /proc/sys/kernel and /sys/kernel ---------------------------------------

fn genHostname(_: *vfs.Node, out: []u8) usize {
    var w = Writer{ .out = out };
    w.str(HOSTNAME);
    w.ch('\n');
    return w.pos;
}

fn genOstype(_: *vfs.Node, out: []u8) usize {
    var w = Writer{ .out = out };
    w.str(OSTYPE);
    w.ch('\n');
    return w.pos;
}

fn genOsrelease(_: *vfs.Node, out: []u8) usize {
    var w = Writer{ .out = out };
    w.str(OSRELEASE);
    w.ch('\n');
    return w.pos;
}

fn genKversion(_: *vfs.Node, out: []u8) usize {
    var w = Writer{ .out = out };
    w.str(KVERSION);
    w.ch('\n');
    return w.pos;
}

// ---- per-process generators -------------------------------------------------

/// Map a per-pid node back to its process. gen_arg==0 means /proc/self (the
/// reader); otherwise gen_arg holds pid+1.
fn resolveProc(node: *vfs.Node) ?*process.Process {
    if (node.gen_arg == 0) return process.current();
    return process.byPid(@intCast(node.gen_arg - 1));
}

fn commName(p: *process.Process, buf: []u8) []const u8 {
    if (p.argc == 0) {
        const d = if (p.pid == 0) "kernel" else "?";
        const n = @min(d.len, buf.len);
        @memcpy(buf[0..n], d[0..n]);
        return buf[0..n];
    }
    var av: [process.MAX_ARGS][]const u8 = undefined;
    const args = process.argvSlices(p, &av);
    const a0 = args[0];
    var start: usize = 0;
    var k: usize = 0;
    while (k < a0.len) : (k += 1) {
        if (a0[k] == '/') start = k + 1;
    }
    const base = a0[start..];
    const n = @min(base.len, buf.len);
    @memcpy(buf[0..n], base[0..n]);
    return buf[0..n];
}

fn genPidStatus(node: *vfs.Node, out: []u8) usize {
    var w = Writer{ .out = out };
    const p = resolveProc(node) orelse return 0;
    var nbuf: [64]u8 = undefined;
    w.str("Name:\t");
    w.str(commName(p, &nbuf));
    w.ch('\n');
    w.str("State:\t");
    w.ch(process.stateChar(p));
    w.str(if (process.isLive(p) and process.stateChar(p) == 'Z')
        " (zombie)\n"
    else
        " (running)\n");
    w.str("Pid:\t");
    w.dec(p.pid);
    w.ch('\n');
    w.str("PPid:\t");
    w.dec(p.ppid);
    w.ch('\n');
    w.str("Uid:\t");
    w.dec(p.uid);
    w.ch('\t');
    w.dec(p.euid);
    w.ch('\t');
    w.dec(p.euid);
    w.ch('\t');
    w.dec(p.euid);
    w.ch('\n');
    w.str("Gid:\t");
    w.dec(p.gid);
    w.ch('\t');
    w.dec(p.egid);
    w.ch('\t');
    w.dec(p.egid);
    w.ch('\t');
    w.dec(p.egid);
    w.ch('\n');
    w.str("Threads:\t1\n");
    return w.pos;
}

fn genPidStat(node: *vfs.Node, out: []u8) usize {
    var w = Writer{ .out = out };
    const p = resolveProc(node) orelse return 0;
    var nbuf: [64]u8 = undefined;
    w.dec(p.pid);
    w.str(" (");
    w.str(commName(p, &nbuf));
    w.str(") ");
    w.ch(process.stateChar(p));
    w.ch(' ');
    w.dec(p.ppid);
    // pgrp session tty_nr tpgid flags minflt cminflt majflt cmajflt
    // utime stime cutime cstime priority nice num_threads ...
    w.str(" 0 0 0 -1 0 0 0 0 0 0 0 0 0 0 0 1 0 0\n");
    return w.pos;
}

fn genPidCmdline(node: *vfs.Node, out: []u8) usize {
    var w = Writer{ .out = out };
    const p = resolveProc(node) orelse return 0;
    if (p.argc == 0) return 0;
    var av: [process.MAX_ARGS][]const u8 = undefined;
    const args = process.argvSlices(p, &av);
    for (args) |a| {
        w.str(a);
        w.ch(0); // NUL-separated, like Linux
    }
    return w.pos;
}

// ---- /proc/<pid> dynamic directory ------------------------------------------

const PidEntry = struct {
    dir: *vfs.Node,
    status: *vfs.Node,
    stat: *vfs.Node,
    cmdline: *vfs.Node,
    namebuf: [12]u8,
};

var pid_entries: [process.MAX_PROC]PidEntry = undefined;

fn fmtPid(pid: u32, buf: *[12]u8) []u8 {
    if (pid == 0) {
        buf[0] = '0';
        return buf[0..1];
    }
    var tmp: [12]u8 = undefined;
    var i: usize = tmp.len;
    var n = pid;
    while (n > 0) : (n /= 10) {
        i -= 1;
        tmp[i] = '0' + @as(u8, @intCast(n % 10));
    }
    const len = tmp.len - i;
    @memcpy(buf[0..len], tmp[i..]);
    return buf[0..len];
}

/// Point pool entry `i` at process `p` and hand back its directory node.
fn fillPid(i: usize, p: *process.Process) *vfs.Node {
    const e = &pid_entries[i];
    e.dir.name = fmtPid(p.pid, &e.namebuf);
    const tag = @as(u64, p.pid) + 1;
    e.status.gen_arg = tag;
    e.stat.gen_arg = tag;
    e.cmdline.gen_arg = tag;
    return e.dir;
}

fn procRootLookup(_: *vfs.Node, name: []const u8) ?*vfs.Node {
    const pid = parseU32(name) orelse return null;
    var i: usize = 0;
    while (i < process.MAX_PROC) : (i += 1) {
        const p = process.slot(i);
        if (process.isLive(p) and p.pid == pid) return fillPid(i, p);
    }
    return null;
}

fn procRootReaddir(_: *vfs.Node, index: usize) ?*vfs.Node {
    var seen: usize = 0;
    var i: usize = 0;
    while (i < process.MAX_PROC) : (i += 1) {
        const p = process.slot(i);
        if (!process.isLive(p)) continue;
        if (seen == index) return fillPid(i, p);
        seen += 1;
    }
    return null;
}

const proc_synth = vfs.SynthDir{ .lookup = procRootLookup, .readdir = procRootReaddir };

fn initPidPool() vfs.Error!void {
    var i: usize = 0;
    while (i < process.MAX_PROC) : (i += 1) {
        const e = &pid_entries[i];
        e.dir = try vfs.newNode(.dir, "0");
        e.status = try vfs.newNode(.file, "status");
        e.stat = try vfs.newNode(.file, "stat");
        e.cmdline = try vfs.newNode(.file, "cmdline");
        e.status.gen = genPidStatus;
        e.stat.gen = genPidStat;
        e.cmdline.gen = genPidCmdline;
        try vfs.link(e.dir, e.status);
        try vfs.link(e.dir, e.stat);
        try vfs.link(e.dir, e.cmdline);
    }
}

// ---- tree construction ------------------------------------------------------

pub fn init() vfs.Error!void {
    const proc = try vfs.mkdirMem("/proc");
    proc.synth = &proc_synth;

    _ = try vfs.mkgen("/proc/version", genVersion);
    _ = try vfs.mkgen("/proc/uptime", genUptime);
    _ = try vfs.mkgen("/proc/meminfo", genMeminfo);
    _ = try vfs.mkgen("/proc/cpuinfo", genCpuinfo);
    _ = try vfs.mkgen("/proc/stat", genStat);
    _ = try vfs.mkgen("/proc/loadavg", genLoadavg);
    _ = try vfs.mkgen("/proc/filesystems", genFilesystems);
    _ = try vfs.mkgen("/proc/mounts", genMounts);
    _ = try vfs.mkgen("/proc/cmdline", genCmdline);

    // /proc/self — the reading process (gen_arg stays 0).
    _ = try vfs.mkdirMem("/proc/self");
    _ = try vfs.mkgen("/proc/self/status", genPidStatus);
    _ = try vfs.mkgen("/proc/self/stat", genPidStat);
    _ = try vfs.mkgen("/proc/self/cmdline", genPidCmdline);

    // /proc/sys/kernel — sysctl-style identity.
    _ = try vfs.mkdirMem("/proc/sys");
    _ = try vfs.mkdirMem("/proc/sys/kernel");
    _ = try vfs.mkgen("/proc/sys/kernel/hostname", genHostname);
    _ = try vfs.mkgen("/proc/sys/kernel/ostype", genOstype);
    _ = try vfs.mkgen("/proc/sys/kernel/osrelease", genOsrelease);
    _ = try vfs.mkgen("/proc/sys/kernel/version", genKversion);

    // /sys skeleton — enough that tools probing it find a sane shape.
    _ = try vfs.mkdirMem("/sys");
    _ = try vfs.mkdirMem("/sys/kernel");
    _ = try vfs.mkgen("/sys/kernel/hostname", genHostname);
    _ = try vfs.mkgen("/sys/kernel/ostype", genOstype);
    _ = try vfs.mkgen("/sys/kernel/osrelease", genOsrelease);
    _ = try vfs.mkdirMem("/sys/devices");
    _ = try vfs.mkdirMem("/sys/class");
    _ = try vfs.mkdirMem("/sys/block");
    _ = try vfs.mkdirMem("/sys/bus");
    _ = try vfs.mkdirMem("/sys/firmware");
    _ = try vfs.mkdirMem("/sys/module");

    try initPidPool();
}
