//! ZInit — Nevara's init system (PID 1), on the nstd runtime.
//!
//! A real supervisor, not just a getty loop:
//!   * Reads a service table from /etc/zinit.conf.
//!   * Starts services (fork + execve) and reaps them with waitpid(WNOHANG).
//!   * Restarts crashed services with exponential back-off.
//!   * Runlevels / targets: single (maintenance shell only), multi (all
//!     services), reboot, poweroff (via the SYS_reboot syscall).
//!   * Accepts control commands from `zinit-ctl` through a polled command file
//!     (/var/run/zinit.ctl) and publishes a status snapshot to
//!     /var/run/zinit.status.
//!   * Logs lifecycle events to /var/log/syslog, rotated at 1 MiB.
//!
//! Note: the kernel has no signals yet, so `stop`/`restart` of an already
//! running service cannot forcibly kill it — they take effect on the service's
//! next exit (stop disables respawn; restart re-enables it). Forceful
//! termination waits on Phase II-E signals.

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

// ---- open() flags (match the kernel) ---------------------------------------
const O_RDONLY: usize = 0;
const O_CREAT: usize = 0o100;
const O_TRUNC: usize = 0o1000;
const O_APPEND: usize = 0o2000;
const SEEK_END: usize = 2;
const WNOHANG: usize = 1;

const SYSLOG_MAX: isize = 1024 * 1024; // rotate /var/log/syslog at 1 MiB

// ---- Service table ----------------------------------------------------------
const MAX_SVCS = 16;
const MAX_ARGS = 8;
const LINE = 256;
const BACKOFF_MAX: u64 = 30; // seconds
const BACKOFF_RESET: u64 = 60; // a service up this long resets its back-off

const Policy = enum { respawn, once, wait };
const SvcState = enum { stopped, running, exited };
const Target = enum { single, multi };

const Service = struct {
    used: bool = false,
    name: [32]u8 = [_]u8{0} ** 32,
    name_len: usize = 0,
    line: [LINE]u8 = [_]u8{0} ** LINE, // backing store for the argv strings
    argv: [MAX_ARGS + 1]?[*:0]const u8 = [_]?[*:0]const u8{null} ** (MAX_ARGS + 1),
    path: [*:0]const u8 = "",
    is_shell: bool = false, // a /bin/nsh service kept alive even in single mode
    policy: Policy = .respawn,
    state: SvcState = .stopped,
    enabled: bool = true,
    pid: isize = -1,
    exit_code: i32 = 0,
    backoff: u64 = 0,
    restart_at: u64 = 0, // uptime-seconds deadline for the next (re)start
    started_at: u64 = 0,
    restarts: u32 = 0,
};

var services: [MAX_SVCS]Service = [_]Service{.{}} ** MAX_SVCS;
var svc_count: usize = 0;
var target: Target = .multi;
var pending_shutdown: isize = -1; // -1 none, 0 poweroff, 1 reboot

// =====================================================================
//  Small helpers
// =====================================================================

fn nowSecs() u64 {
    return nstd.uptimeTicks() / 100;
}

fn eqStr(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, 0..) |c, i| if (c != b[i]) return false;
    return true;
}

/// A fixed-capacity string builder for status/log lines.
const Buf = struct {
    data: [768]u8 = undefined,
    len: usize = 0,

    fn reset(self: *Buf) void {
        self.len = 0;
    }
    fn str(self: *Buf, s: []const u8) void {
        const n = @min(s.len, self.data.len - self.len);
        @memcpy(self.data[self.len .. self.len + n], s[0..n]);
        self.len += n;
    }
    fn ch(self: *Buf, c: u8) void {
        if (self.len < self.data.len) {
            self.data[self.len] = c;
            self.len += 1;
        }
    }
    fn dec(self: *Buf, value: u64) void {
        var tmp: [20]u8 = undefined;
        var i: usize = 0;
        var v = value;
        if (v == 0) {
            self.ch('0');
            return;
        }
        while (v > 0) : (v /= 10) {
            tmp[i] = '0' + @as(u8, @intCast(v % 10));
            i += 1;
        }
        while (i > 0) {
            i -= 1;
            self.ch(tmp[i]);
        }
    }
    /// Pad with spaces to at least `width` columns (left-justified text).
    fn pad(self: *Buf, from: usize, width: usize) void {
        while (self.len - from < width) self.ch(' ');
    }
    fn slice(self: *Buf) []const u8 {
        return self.data[0..self.len];
    }
};

fn writeFileTrunc(path: [*:0]const u8, data: []const u8) void {
    const fd = nstd.open(path, O_CREAT | O_TRUNC);
    if (fd < 0) return;
    _ = nstd.write(@intCast(fd), data);
    nstd.close(@intCast(fd));
}

fn readWholeFile(path: [*:0]const u8, buf: []u8) usize {
    const fd = nstd.open(path, O_RDONLY);
    if (fd < 0) return 0;
    var total: usize = 0;
    while (total < buf.len) {
        const n = nstd.read(@intCast(fd), buf[total..]);
        if (n == 0) break;
        total += n;
    }
    nstd.close(@intCast(fd));
    return total;
}

// =====================================================================
//  Syslog (file-backed, rotated at 1 MiB)
// =====================================================================

fn syslog(msg: []const u8) void {
    var b: Buf = .{};
    b.ch('[');
    b.dec(nowSecs());
    b.str("] zinit: ");
    b.str(msg);
    b.ch('\n');

    // Mirror to the console so the boot log shows supervision activity.
    nstd.print(b.slice());

    // Rotate if the log has grown past the cap.
    const probe = nstd.open("/var/log/syslog", O_RDONLY);
    if (probe >= 0) {
        const size = nstd.lseek(@intCast(probe), 0, SEEK_END);
        nstd.close(@intCast(probe));
        if (size >= SYSLOG_MAX) {
            _ = nstd.renameFile("/var/log/syslog", "/var/log/syslog.0");
        }
    }

    const fd = nstd.open("/var/log/syslog", O_CREAT | O_APPEND);
    if (fd < 0) return;
    _ = nstd.write(@intCast(fd), b.slice());
    nstd.close(@intCast(fd));
}

/// Log "<prefix><service name><suffix>".
fn syslogSvc(prefix: []const u8, svc: *const Service, suffix: []const u8) void {
    var b: Buf = .{};
    b.str(prefix);
    b.str(svc.name[0..svc.name_len]);
    b.str(suffix);
    syslog(b.slice());
}

// =====================================================================
//  Config parsing
// =====================================================================

fn parseServiceLine(svc: *Service, line: []const u8) bool {
    if (line.len == 0 or line.len >= LINE) return false;
    @memcpy(svc.line[0..line.len], line);
    svc.line[line.len] = 0;

    // Tokenize in place: replace separators with NUL, record token starts.
    var starts: [MAX_ARGS + 3]usize = undefined;
    var ntok: usize = 0;
    var i: usize = 0;
    while (i < line.len and ntok < starts.len) {
        while (i < line.len and (svc.line[i] == ' ' or svc.line[i] == '\t')) : (i += 1) {}
        if (i >= line.len) break;
        starts[ntok] = i;
        ntok += 1;
        while (i < line.len and svc.line[i] != ' ' and svc.line[i] != '\t') : (i += 1) {}
        if (i < line.len) {
            svc.line[i] = 0;
            i += 1;
        }
    }
    if (ntok < 3) return false; // need: name policy path

    // name
    const nm = nstd.span(@ptrCast(&svc.line[starts[0]]));
    svc.name_len = @min(nm.len, svc.name.len);
    @memcpy(svc.name[0..svc.name_len], nm[0..svc.name_len]);

    // policy
    const pol = nstd.span(@ptrCast(&svc.line[starts[1]]));
    if (eqStr(pol, "respawn")) {
        svc.policy = .respawn;
    } else if (eqStr(pol, "once")) {
        svc.policy = .once;
    } else if (eqStr(pol, "wait")) {
        svc.policy = .wait;
    } else return false;

    // argv = path + remaining args
    var ai: usize = 0;
    var t: usize = 2;
    while (t < ntok and ai < MAX_ARGS) : (t += 1) {
        svc.argv[ai] = @ptrCast(&svc.line[starts[t]]);
        ai += 1;
    }
    svc.argv[ai] = null;
    svc.path = svc.argv[0].?;
    svc.is_shell = eqStr(nstd.span(svc.path), "/bin/nsh");
    svc.used = true;
    svc.enabled = true;
    svc.state = .stopped;
    return true;
}

fn addDefaultShell() void {
    if (svc_count >= MAX_SVCS) return;
    _ = parseServiceLine(&services[svc_count], "shell respawn /bin/nsh");
    svc_count += 1;
}

fn loadConfig() void {
    var buf: [4096]u8 = undefined;
    const n = readWholeFile("/etc/zinit.conf", &buf);
    if (n == 0) {
        syslog("no /etc/zinit.conf; using built-in default (respawn shell)");
        addDefaultShell();
        return;
    }

    var i: usize = 0;
    while (i < n and svc_count < MAX_SVCS) {
        // slice one line
        const start = i;
        while (i < n and buf[i] != '\n') : (i += 1) {}
        var line = buf[start..i];
        if (i < n) i += 1; // skip '\n'
        // trim trailing CR / spaces
        while (line.len > 0 and (line[line.len - 1] == '\r' or line[line.len - 1] == ' ')) {
            line = line[0 .. line.len - 1];
        }
        // trim leading spaces
        var s: usize = 0;
        while (s < line.len and (line[s] == ' ' or line[s] == '\t')) : (s += 1) {}
        line = line[s..];
        if (line.len == 0 or line[0] == '#') continue;

        // "target single|multi" directive
        if (line.len > 7 and eqStr(line[0..7], "target ")) {
            const val = line[7..];
            if (eqStr(val, "single")) target = .single else if (eqStr(val, "multi")) target = .multi;
            continue;
        }

        if (parseServiceLine(&services[svc_count], line)) {
            svc_count += 1;
        }
    }

    if (svc_count == 0) addDefaultShell();
}

// =====================================================================
//  Supervision
// =====================================================================

fn findByPid(pid: isize) ?*Service {
    for (services[0..svc_count]) |*svc| {
        if (svc.used and svc.pid == pid) return svc;
    }
    return null;
}

/// True if this service should be running under the current target.
fn activeUnderTarget(svc: *const Service) bool {
    if (target == .single) return svc.is_shell;
    return true;
}

fn startService(svc: *Service) void {
    const pid = nstd.fork();
    if (pid == 0) {
        _ = nstd.execve(svc.path, &svc.argv);
        // execve only returns on failure.
        nstd.exit(127);
    } else if (pid > 0) {
        svc.pid = pid;
        svc.state = .running;
        svc.started_at = nowSecs();
        svc.restart_at = 0;
        syslogSvc("started service '", svc, "'");
    } else {
        syslogSvc("fork failed for service '", svc, "'; retrying in 5s");
        svc.state = .exited;
        svc.restart_at = nowSecs() + 5;
    }
}

fn scheduleRestart(svc: *Service) void {
    if (!svc.enabled or svc.policy != .respawn or !activeUnderTarget(svc)) {
        svc.state = .stopped;
        return;
    }
    const now = nowSecs();
    if (now - svc.started_at >= BACKOFF_RESET) svc.backoff = 0;
    svc.backoff = if (svc.backoff == 0) 1 else @min(svc.backoff * 2, BACKOFF_MAX);
    svc.restart_at = now + svc.backoff;
    svc.restarts += 1;

    var b: Buf = .{};
    b.str("service '");
    b.str(svc.name[0..svc.name_len]);
    b.str("' exited (code ");
    b.dec(@intCast(@as(u32, @bitCast(svc.exit_code)) & 0xff));
    b.str("); restart in ");
    b.dec(svc.backoff);
    b.str("s");
    syslog(b.slice());
}

/// Reap any exited children (non-blocking). PID 1 also reaps orphans.
fn reapChildren() void {
    while (true) {
        var st: u32 = 0;
        const r = nstd.waitpid(-1, &st, WNOHANG);
        if (r <= 0) break;
        if (findByPid(r)) |svc| {
            svc.pid = -1;
            svc.exit_code = @intCast((st >> 8) & 0xff);
            svc.state = .exited;
            scheduleRestart(svc);
        }
        // Unknown pid: a reparented orphan we just cleaned up. Nothing to do.
    }
}

/// Start every service that is due (boot start or scheduled restart).
/// Returns true if any service was started this pass.
fn startDueServices() bool {
    const now = nowSecs();
    var did = false;
    for (services[0..svc_count]) |*svc| {
        if (!svc.used or !svc.enabled) continue;
        if (svc.state == .running) continue;
        if (!activeUnderTarget(svc)) continue;
        // once/wait services never auto-(re)start once they have run.
        if (svc.policy != .respawn and svc.restarts > 0) continue;
        if (svc.state == .exited and svc.policy != .respawn) continue;
        if (now < svc.restart_at) continue;
        startService(svc);
        did = true;
    }
    return did;
}

/// Boot sequence: run `wait` (oneshot, blocking) services to completion in
/// order, then kick off the rest.
fn bootSequence() void {
    for (services[0..svc_count]) |*svc| {
        if (!svc.used or svc.policy != .wait) continue;
        if (!activeUnderTarget(svc)) continue;
        startService(svc);
        if (svc.pid > 0) {
            var st: u32 = 0;
            _ = nstd.waitpid(svc.pid, &st, 0); // block until it finishes
            svc.pid = -1;
            svc.exit_code = @intCast((st >> 8) & 0xff);
            svc.state = .stopped;
            svc.restarts += 1;
            syslogSvc("oneshot '", svc, "' completed");
        }
    }
    _ = startDueServices();
}

// =====================================================================
//  Status snapshot
// =====================================================================

fn stateName(s: SvcState) []const u8 {
    return switch (s) {
        .stopped => "stopped",
        .running => "running",
        .exited => "exited",
    };
}

fn policyName(p: Policy) []const u8 {
    return switch (p) {
        .respawn => "respawn",
        .once => "once",
        .wait => "wait",
    };
}

fn writeStatus() void {
    var b: Buf = .{};
    b.str("target ");
    b.str(if (target == .single) "single" else "multi");
    b.ch('\n');
    var col = b.len;
    b.str("NAME");
    b.pad(col, 12);
    col = b.len;
    b.str("STATE");
    b.pad(col, 10);
    col = b.len;
    b.str("PID");
    b.pad(col, 8);
    col = b.len;
    b.str("POLICY");
    b.pad(col, 10);
    b.str("RESTARTS\n");

    for (services[0..svc_count]) |*svc| {
        if (!svc.used) continue;
        col = b.len;
        b.str(svc.name[0..svc.name_len]);
        b.pad(col, 12);
        col = b.len;
        b.str(stateName(svc.state));
        b.pad(col, 10);
        col = b.len;
        if (svc.pid > 0) b.dec(@intCast(svc.pid)) else b.ch('-');
        b.pad(col, 8);
        col = b.len;
        b.str(policyName(svc.policy));
        if (!svc.enabled) b.str("*");
        b.pad(col, 10);
        b.dec(svc.restarts);
        b.ch('\n');
    }
    writeFileTrunc("/var/run/zinit.status", b.slice());
}

// =====================================================================
//  Control channel (/var/run/zinit.ctl, polled)
// =====================================================================

fn findByName(name: []const u8) ?*Service {
    for (services[0..svc_count]) |*svc| {
        if (svc.used and eqStr(svc.name[0..svc.name_len], name)) return svc;
    }
    return null;
}

fn handleCommand(line: []const u8) void {
    // split into verb + optional argument
    var i: usize = 0;
    while (i < line.len and line[i] != ' ') : (i += 1) {}
    const verb = line[0..i];
    while (i < line.len and line[i] == ' ') : (i += 1) {}
    const arg = line[i..];

    if (eqStr(verb, "reboot")) {
        pending_shutdown = 1;
    } else if (eqStr(verb, "poweroff")) {
        pending_shutdown = 0;
    } else if (eqStr(verb, "single")) {
        target = .single;
        syslog("switching to target: single");
        for (services[0..svc_count]) |*svc| {
            if (svc.used and !svc.is_shell) svc.enabled = false;
        }
    } else if (eqStr(verb, "multi")) {
        target = .multi;
        syslog("switching to target: multi");
        for (services[0..svc_count]) |*svc| {
            if (svc.used) svc.enabled = true;
        }
    } else if (eqStr(verb, "start")) {
        if (findByName(arg)) |svc| {
            svc.enabled = true;
            svc.backoff = 0;
            svc.restart_at = 0;
            if (svc.state != .running) svc.state = .exited;
            syslogSvc("control: start '", svc, "'");
        }
    } else if (eqStr(verb, "stop")) {
        if (findByName(arg)) |svc| {
            svc.enabled = false;
            if (svc.state == .running) {
                syslogSvc("control: stop '", svc, "' (effective on next exit; no kill yet)");
            } else {
                svc.state = .stopped;
                syslogSvc("control: stop '", svc, "'");
            }
        }
    } else if (eqStr(verb, "restart")) {
        if (findByName(arg)) |svc| {
            svc.enabled = true;
            svc.backoff = 0;
            svc.restart_at = 0;
            if (svc.state != .running) svc.state = .exited;
            syslogSvc("control: restart '", svc, "' (running ones restart on next exit)");
        }
    }
}

fn pollControl() void {
    var buf: [512]u8 = undefined;
    const n = readWholeFile("/var/run/zinit.ctl", &buf);
    if (n == 0) return;
    // consume the file so commands run exactly once
    writeFileTrunc("/var/run/zinit.ctl", "");

    var i: usize = 0;
    while (i < n) {
        const start = i;
        while (i < n and buf[i] != '\n') : (i += 1) {}
        var line = buf[start..i];
        if (i < n) i += 1;
        while (line.len > 0 and (line[line.len - 1] == '\r' or line[line.len - 1] == ' ')) {
            line = line[0 .. line.len - 1];
        }
        if (line.len > 0) handleCommand(line);
    }
}

fn doShutdown() noreturn {
    const mode = pending_shutdown;
    syslog(if (mode == 1) "rebooting" else "powering off");
    writeStatus();
    // No signals: we cannot kill running services, but the kernel tears every
    // process down when we halt the machine. Hand off to the kernel.
    _ = nstd.reboot(@intCast(mode));
    // Should never return; if the platform ignored us, idle forever.
    while (true) nstd.sleep(60);
}

// =====================================================================
//  Entry
// =====================================================================

fn ensureDirs() void {
    _ = nstd.mkdir("/var");
    _ = nstd.mkdir("/var/log");
    _ = nstd.mkdir("/var/run");
}

pub fn main() void {
    nstd.print("[zinit] PID 1 up — supervisor starting\n");
    ensureDirs();
    syslog("init started (PID 1)");

    loadConfig();
    var b: Buf = .{};
    b.str("loaded ");
    b.dec(svc_count);
    b.str(" service(s); target ");
    b.str(if (target == .single) "single" else "multi");
    syslog(b.slice());

    bootSequence();

    // Supervision loop: reap, restart with back-off, serve control commands.
    while (true) {
        reapChildren();
        pollControl();
        if (pending_shutdown >= 0) doShutdown();
        const did = startDueServices();
        writeStatus();
        // Idle a beat when there was nothing to do, so we don't spin the CPU.
        if (!did) nstd.sleep(1);
    }
}
