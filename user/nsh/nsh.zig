//! nsh — the Nevara shell. A REPL on nstd: read a line, parse it into argv, then
//! fork + execve a /bin/<cmd> child and wait for it (or run it in the background
//! with a trailing `&`). The `demo` builtin shows preemptive multitasking by
//! forking two children whose output interleaves.

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

const MAX_ARGS = 16;

var line: [256]u8 = undefined;
var path: [288]u8 = undefined;
var argv: [MAX_ARGS + 1]?[*:0]const u8 = undefined;

pub fn main() void {
    nstd.print("\n\x1b[1;36mNevara shell (nsh)\x1b[0m - type 'help' or 'exit'\n");

    while (true) {
        reapBackground();
        nstd.print("\x1b[1;32mnevara$\x1b[0m ");
        const n = nstd.read(0, line[0 .. line.len - 1]);
        if (n == 0) continue;

        var len = n;
        if (len > 0 and line[len - 1] == '\n') len -= 1;

        // A trailing '&' (after optional spaces) means run in the background.
        var bg = false;
        while (len > 0 and line[len - 1] == ' ') len -= 1;
        if (len > 0 and line[len - 1] == '&') {
            bg = true;
            len -= 1;
            while (len > 0 and line[len - 1] == ' ') len -= 1;
        }
        line[len] = 0;

        const argc = parse(len);
        if (argc == 0) continue;

        const cmd = std.mem.span(argv[0].?);
        if (std.mem.eql(u8, cmd, "exit")) return;
        if (std.mem.eql(u8, cmd, "help")) {
            help();
            continue;
        }
        if (std.mem.eql(u8, cmd, "demo")) {
            demo();
            continue;
        }

        const p = buildPath(cmd);
        const pid = nstd.fork();
        if (pid == 0) {
            // Child: become the requested program.
            _ = nstd.execve(p, &argv);
            nstd.print("nsh: command not found: ");
            nstd.print(cmd);
            nstd.print("\n");
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
}

fn help() void {
    nstd.print("builtins: help, exit, demo\n");
    nstd.print("programs in /bin: nevbox, echo, cat, ls, hello\n");
    nstd.print("run in background with a trailing '&'\n");
    nstd.print("line editing: \x1b[33m<-/->\x1b[0m move, Home/End, Del,\n");
    nstd.print("  Ctrl-A/E/U/K/W, Up/Down history, Ctrl-L clear\n");
}

/// Reap any finished background children (non-blocking).
fn reapBackground() void {
    var st: u32 = 0;
    while (nstd.waitpid(-1, &st, 1) > 0) {}
}

/// `demo`: fork two CPU-bound children; the 100 Hz timer preempts them so their
/// output interleaves, proving preemptive multitasking. The parent waits both.
fn demo() void {
    nstd.print("demo: two children running concurrently\n");
    var k: usize = 0;
    while (k < 2) : (k += 1) {
        const pid = nstd.fork();
        if (pid == 0) {
            childWork(k);
            nstd.exit(0);
        }
    }
    var st: u32 = 0;
    _ = nstd.waitpid(-1, &st, 0);
    _ = nstd.waitpid(-1, &st, 0);
    nstd.print("demo: both children done\n");
}

fn childWork(k: usize) void {
    var i: usize = 0;
    while (i < 6) : (i += 1) {
        // One write() per line so lines interleave cleanly, not characters.
        var b: [12]u8 = undefined;
        b[0] = ' ';
        b[1] = ' ';
        b[2] = '[';
        b[3] = 'c';
        b[4] = '0' + @as(u8, @intCast(k));
        b[5] = ']';
        b[6] = ' ';
        b[7] = '0' + @as(u8, @intCast(i));
        b[8] = '\n';
        nstd.print(b[0..9]);
        delay();
    }
}

fn delay() void {
    var s: usize = 0;
    while (s < 8_000_000) : (s += 1) asm volatile ("" ::: .{ .memory = true });
}

/// Split `line[0..len]` (NUL-terminated) into argv in place. Returns argc.
fn parse(len: usize) usize {
    var argc: usize = 0;
    var i: usize = 0;
    while (i < len and argc < MAX_ARGS) {
        while (i < len and line[i] == ' ') i += 1; // skip spaces
        if (i >= len) break;
        argv[argc] = @ptrCast(&line[i]);
        argc += 1;
        while (i < len and line[i] != ' ') i += 1; // span the word
        if (i < len) {
            line[i] = 0; // terminate this word
            i += 1;
        }
    }
    argv[argc] = null;
    return argc;
}

/// Form "/bin/<cmd>" in the `path` buffer and return it.
fn buildPath(cmd: []const u8) [*:0]const u8 {
    const prefix = "/bin/";
    @memcpy(path[0..prefix.len], prefix);
    @memcpy(path[prefix.len .. prefix.len + cmd.len], cmd);
    path[prefix.len + cmd.len] = 0;
    return @ptrCast(&path[0]);
}
