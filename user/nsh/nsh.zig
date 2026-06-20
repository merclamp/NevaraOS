//! nsh — the Nevara shell. A minimal REPL on nstd: read a line, parse it into
//! argv, run /bin/<cmd> as a child process via spawn(), repeat.

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
        nstd.print("\x1b[1;32mnevara$\x1b[0m ");
        const n = nstd.read(0, line[0 .. line.len - 1]);
        if (n == 0) continue;

        // Strip the trailing newline and NUL-terminate.
        var len = n;
        if (len > 0 and line[len - 1] == '\n') len -= 1;
        line[len] = 0;

        const argc = parse(len);
        if (argc == 0) continue;

        const cmd = std.mem.span(argv[0].?);
        if (std.mem.eql(u8, cmd, "exit")) return;
        if (std.mem.eql(u8, cmd, "help")) {
            nstd.print("builtins: help, exit\n");
            nstd.print("programs in /bin: nevbox, echo, cat, ls, hello\n");
            nstd.print("line editing: \x1b[33m<-/->\x1b[0m move, Home/End, Del,\n");
            nstd.print("  Ctrl-A/E/U/K/W, Up/Down history, Ctrl-L clear\n");
            continue;
        }

        const p = buildPath(cmd);
        const code = nstd.spawn(p, &argv);
        if (code < 0) {
            nstd.print("nsh: command not found: ");
            nstd.print(cmd);
            nstd.print("\n");
        }
    }
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
