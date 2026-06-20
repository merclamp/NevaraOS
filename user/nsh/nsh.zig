//! nsh — the Nevara shell. Supports pipelines (cmd1 | cmd2), output
//! redirection (> file, >> file), and input redirection (< file).
//! Pipes and redirects are implemented with the real pipe()/dup2() syscalls.

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

// ---- line buffer -----------------------------------------------------------

var line: [512]u8 = undefined;
var line_len: usize = 0;

// ---- pipeline descriptor ---------------------------------------------------

const MAX_SEGS = 8;   // max commands in a pipeline
const MAX_ARGS = 16;

const Redirect = struct {
    input:  ?[*:0]const u8 = null, // < file
    output: ?[*:0]const u8 = null, // > file or >> file
    append: bool = false,
};

const Segment = struct {
    argv: [MAX_ARGS + 1]?[*:0]const u8 = undefined,
    argc: usize = 0,
    redir: Redirect = .{},
};

var segs:  [MAX_SEGS]Segment = undefined;
var nseg:  usize = 0;

// ---- helpers ---------------------------------------------------------------

fn isRedirect(c: u8) bool {
    return c == '>' or c == '<';
}

/// Split `line[0..len]` into pipeline segments separated by '|'.
/// Each segment is further split into argv, consuming '>', '>>', '<' tokens.
fn parseLine(len: usize) bool {
    nseg = 0;
    var i: usize = 0;
    while (i <= len and nseg < MAX_SEGS) {
        var seg = Segment{};
        seg.argc = 0;
        // scan words / redirections until '|' or end
        while (i <= len) {
            // skip spaces
            while (i < len and line[i] == ' ') i += 1;
            if (i >= len or line[i] == '|') break;

            // redirection?
            if (line[i] == '>') {
                i += 1;
                seg.redir.append = (i < len and line[i] == '>');
                if (seg.redir.append) i += 1;
                while (i < len and line[i] == ' ') i += 1;
                const start = i;
                while (i < len and line[i] != ' ' and line[i] != '|') i += 1;
                line[i] = 0;
                seg.redir.output = @ptrCast(&line[start]);
                i += 1;
                continue;
            }
            if (line[i] == '<') {
                i += 1;
                while (i < len and line[i] == ' ') i += 1;
                const start = i;
                while (i < len and line[i] != ' ' and line[i] != '|') i += 1;
                line[i] = 0;
                seg.redir.input = @ptrCast(&line[start]);
                i += 1;
                continue;
            }

            // regular word
            if (seg.argc >= MAX_ARGS) { i += 1; continue; }
            seg.argv[seg.argc] = @ptrCast(&line[i]);
            seg.argc += 1;
            while (i < len and line[i] != ' ' and line[i] != '|'
                             and !isRedirect(line[i])) i += 1;
            if (i < len and (line[i] == ' ' or line[i] == '|' or isRedirect(line[i]))) {
                if (line[i] != '|' and !isRedirect(line[i])) {
                    line[i] = 0;
                    i += 1;
                } else {
                    line[i] = 0;
                }
            }
        }
        seg.argv[seg.argc] = null;
        if (seg.argc == 0 and seg.redir.output == null and seg.redir.input == null)
            break;
        segs[nseg] = seg;
        nseg += 1;
        if (i < len and line[i] == '|') i += 1; // consume '|'
    }
    return nseg > 0 and segs[0].argc > 0;
}

fn buildPath(cmd: []const u8, buf: []u8) ?[*:0]const u8 {
    const prefix = "/bin/";
    if (prefix.len + cmd.len + 1 > buf.len) return null;
    @memcpy(buf[0..prefix.len], prefix);
    @memcpy(buf[prefix.len .. prefix.len + cmd.len], cmd);
    buf[prefix.len + cmd.len] = 0;
    return @ptrCast(buf.ptr);
}

// ---- builtins --------------------------------------------------------------

pub fn main() void {
    nstd.print("\n\x1b[1;36mNevara shell (nsh)\x1b[0m - type 'help' or 'exit'\n");

    while (true) {
        reapBackground();
        nstd.print("\x1b[1;32mnevara$\x1b[0m ");
        const n = nstd.read(0, line[0 .. line.len - 1]);
        if (n == 0) continue;

        line_len = n;
        if (line_len > 0 and line[line_len - 1] == '\n') line_len -= 1;

        // trailing '&' → background
        var bg = false;
        while (line_len > 0 and line[line_len - 1] == ' ') line_len -= 1;
        if (line_len > 0 and line[line_len - 1] == '&') {
            bg = true;
            line_len -= 1;
            while (line_len > 0 and line[line_len - 1] == ' ') line_len -= 1;
        }
        line[line_len] = 0;

        if (!parseLine(line_len)) continue;

        const cmd = std.mem.span(segs[0].argv[0].?);
        if (std.mem.eql(u8, cmd, "exit")) return;
        if (std.mem.eql(u8, cmd, "help")) { help(); continue; }
        if (std.mem.eql(u8, cmd, "demo")) { demo(); continue; }

        runPipeline(bg);
    }
}

fn help() void {
    nstd.print("builtins: help, exit, demo\n");
    nstd.print("programs: /bin/nevbox (echo cat ls mkfile mkdir), /bin/nsh ...\n");
    nstd.print("pipeline: cmd1 | cmd2 | ...\n");
    nstd.print("redirect: cmd > file   cmd >> file   cmd < file\n");
    nstd.print("background: cmd &\n");
    nstd.print("line editing: arrows, Home/End, Ctrl-A/E/U/K/W, Up/Down history\n");
}

fn reapBackground() void {
    var st: u32 = 0;
    while (nstd.waitpid(-1, &st, 1) > 0) {}
}

// ---- pipeline execution ----------------------------------------------------

/// Run the parsed pipeline (segs[0..nseg]).
/// For a single command this is just fork+exec+wait.
/// For multiple commands we create nseg-1 pipes, fork each segment, and wait.
fn runPipeline(bg: bool) void {
    if (nseg == 1) {
        runSingle(&segs[0], bg);
        return;
    }

    // Create pipes: pipes[i] connects segs[i] stdout → segs[i+1] stdin.
    var pipes: [MAX_SEGS - 1][2]u32 = undefined;
    var np: usize = 0;
    while (np < nseg - 1) : (np += 1) {
        if (nstd.pipe(&pipes[np]) < 0) {
            nstd.print("nsh: pipe failed\n");
            return;
        }
    }

    var pids: [MAX_SEGS]isize = undefined;
    var pi: usize = 0;
    while (pi < nseg) : (pi += 1) {
        const pid = nstd.fork();
        if (pid == 0) {
            // Child: wire up stdin/stdout, close all pipe fds.
            if (pi > 0) {
                _ = nstd.dup2(pipes[pi - 1][0], 0); // read end of prev pipe → stdin
            }
            if (pi < nseg - 1) {
                _ = nstd.dup2(pipes[pi][1], 1); // write end of this pipe → stdout
            }
            // Close all pipe fds (they're now dup'd to 0/1).
            var ci: usize = 0;
            while (ci < nseg - 1) : (ci += 1) {
                nstd.close(pipes[ci][0]);
                nstd.close(pipes[ci][1]);
            }
            execSeg(&segs[pi]);
            nstd.exit(127);
        }
        pids[pi] = pid;
    }

    // Parent: close all pipe fds (children hold them).
    var ci: usize = 0;
    while (ci < nseg - 1) : (ci += 1) {
        nstd.close(pipes[ci][0]);
        nstd.close(pipes[ci][1]);
    }

    // Wait for all children.
    var st: u32 = 0;
    pi = 0;
    while (pi < nseg) : (pi += 1) {
        if (pids[pi] > 0) _ = nstd.waitpid(pids[pi], &st, 0);
    }
}

fn runSingle(seg: *Segment, bg: bool) void {
    const pid = nstd.fork();
    if (pid == 0) {
        execSeg(seg);
        nstd.exit(127);
    } else if (pid > 0) {
        if (bg) {
            nstd.print("[bg ");
            nstd.printDec(@intCast(pid));
            nstd.print("]\n");
        } else {
            var st: u32 = 0;
            _ = nstd.waitpid(pid, &st, 0);
        }
    } else {
        nstd.print("nsh: fork failed\n");
    }
}

/// Apply redirections and execve. Calls nstd.exit on failure — never returns.
fn execSeg(seg: *Segment) noreturn {
    // Output redirection: > or >>
    if (seg.redir.output) |outpath| {
        const flags: usize = if (seg.redir.append) 0o100 | 0o2000 else 0o100 | 0o1000;
        const fd = nstd.open(outpath, flags);
        if (fd < 0) {
            nstd.print("nsh: cannot open output file\n");
            nstd.exit(1);
        }
        _ = nstd.dup2(@intCast(fd), 1);
        nstd.close(@intCast(fd));
    }
    // Input redirection: <
    if (seg.redir.input) |inpath| {
        const fd = nstd.open(inpath, 0);
        if (fd < 0) {
            nstd.print("nsh: cannot open input file\n");
            nstd.exit(1);
        }
        _ = nstd.dup2(@intCast(fd), 0);
        nstd.close(@intCast(fd));
    }
    if (seg.argc == 0) nstd.exit(0);

    var pathbuf: [288]u8 = undefined;
    const cmd = std.mem.span(seg.argv[0].?);
    const p = buildPath(cmd, &pathbuf) orelse {
        nstd.print("nsh: path too long\n");
        nstd.exit(1);
    };
    _ = nstd.execve(p, &seg.argv);
    nstd.print("nsh: command not found: ");
    nstd.print(cmd);
    nstd.print("\n");
    nstd.exit(127);
}

// ---- demo ------------------------------------------------------------------

fn demo() void {
    nstd.print("demo: two children running concurrently\n");
    var k: usize = 0;
    while (k < 2) : (k += 1) {
        const pid = nstd.fork();
        if (pid == 0) { childWork(k); nstd.exit(0); }
    }
    var st: u32 = 0;
    _ = nstd.waitpid(-1, &st, 0);
    _ = nstd.waitpid(-1, &st, 0);
    nstd.print("demo: both children done\n");
}

fn childWork(k: usize) void {
    var i: usize = 0;
    while (i < 6) : (i += 1) {
        var b: [12]u8 = undefined;
        b[0] = ' '; b[1] = ' '; b[2] = '['; b[3] = 'c';
        b[4] = '0' + @as(u8, @intCast(k));
        b[5] = ']'; b[6] = ' ';
        b[7] = '0' + @as(u8, @intCast(i));
        b[8] = '\n';
        nstd.print(b[0..9]);
        var s: usize = 0;
        while (s < 8_000_000) : (s += 1) asm volatile ("" ::: .{ .memory = true });
    }
}
