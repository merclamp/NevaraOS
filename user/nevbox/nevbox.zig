//! NevBox — Nevara's multi-call userland utility (BusyBox-style), on nstd.
//!
//! One binary, many applets, dispatched by argv[0]'s basename. No C, no libc.

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

fn basename(path: []const u8) []const u8 {
    var start: usize = 0;
    var i: usize = 0;
    while (i < path.len) : (i += 1) {
        if (path[i] == '/') start = i + 1;
    }
    return path[start..];
}

// ---- helpers ---------------------------------------------------------------

fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

/// Parse a non-negative decimal integer from `s`. Returns null on bad input.
fn parseNat(s: []const u8) ?usize {
    if (s.len == 0) return null;
    var v: usize = 0;
    for (s) |c| {
        if (c < '0' or c > '9') return null;
        v = v * 10 + (c - '0');
    }
    return v;
}

// ---- dispatch --------------------------------------------------------------

pub fn main() void {
    const argv0 = nstd.arg(0) orelse "nevbox";
    const cmd = basename(argv0);

    if      (eq(cmd, "echo"))    appletEcho()
    else if (eq(cmd, "cat"))     appletCat()
    else if (eq(cmd, "ls"))      appletLs()
    else if (eq(cmd, "mkfile"))  appletMkfile()
    else if (eq(cmd, "mkdir"))   appletMkdir()
    else if (eq(cmd, "wc"))      appletWc()
    else if (eq(cmd, "grep"))    appletGrep()
    else if (eq(cmd, "head"))    appletHead()
    else if (eq(cmd, "tail"))    appletTail()
    else if (eq(cmd, "cp"))      appletCp()
    else if (eq(cmd, "touch"))   appletTouch()
    else if (eq(cmd, "seq"))     appletSeq()
    else if (eq(cmd, "tee"))     appletTee()
    else if (eq(cmd, "true"))    appletTrue()
    else if (eq(cmd, "false"))   appletFalse()
    else if (eq(cmd, "uptime"))  appletUptime()
    else if (eq(cmd, "uname"))    appletUname()
    else if (eq(cmd, "nevfetch")) appletNevfetch()
    else if (eq(cmd, "sort"))     appletSort()
    else if (eq(cmd, "uniq"))     appletUniq()
    else if (eq(cmd, "cut"))      appletCut()
    else if (eq(cmd, "tr"))       appletTr()
    else if (eq(cmd, "rev"))      appletRev()
    else if (eq(cmd, "pwd"))      appletPwd()
    else if (eq(cmd, "yes"))      appletYes()
    else if (eq(cmd, "basename")) appletBasename()
    else if (eq(cmd, "dirname"))  appletDirname()
    else if (eq(cmd, "rm"))       appletRm()
    else if (eq(cmd, "mv"))       appletMv()
    else if (eq(cmd, "sleep"))    appletSleep()
    else if (eq(cmd, "chmod"))    appletChmod()
    else if (eq(cmd, "find"))     appletFind()
    else if (eq(cmd, "stat"))     appletStat()
    else if (eq(cmd, "strings"))  appletStrings()
    else if (eq(cmd, "fold"))     appletFold()
    else if (eq(cmd, "comm"))     appletComm()
    else if (eq(cmd, "printf"))   appletPrintf()
    else if (eq(cmd, "which"))    appletWhich()
    else if (eq(cmd, "xargs"))    appletXargs()
    else if (eq(cmd, "ln"))       appletLn()
    else if (eq(cmd, "env"))      appletEnv()
    else if (eq(cmd, "dd"))       appletDd()
    else if (eq(cmd, "od"))       appletOd()
    else if (eq(cmd, "nl"))       appletNl()
    else if (eq(cmd, "du"))       appletDu()
    else nstd.print("nevbox: applets: echo cat ls mkfile mkdir " ++
                    "wc grep head tail cp touch seq tee true false " ++
                    "uptime uname nevfetch sort uniq cut tr rev " ++
                    "pwd yes basename dirname rm mv sleep chmod " ++
                    "find stat strings fold comm printf which xargs " ++
                    "ln env dd od nl du\n");

}

// ---- echo ------------------------------------------------------------------

fn appletEcho() void {
    var i: usize = 1;
    while (nstd.arg(i)) |a| : (i += 1) {
        if (i > 1) nstd.print(" ");
        nstd.print(a);
    }
    nstd.print("\n");
}

// ---- mkfile ----------------------------------------------------------------

fn appletMkfile() void {
    const path = nstd.argZ(1) orelse {
        nstd.print("usage: mkfile <path> <text...>\n");
        return;
    };
    const fd_raw = nstd.open(path, 0o100 | 0o1000); // O_CREAT | O_TRUNC
    if (fd_raw < 0) { nstd.print("mkfile: cannot create file\n"); return; }
    const fd: usize = @intCast(fd_raw);
    var i: usize = 2;
    var first = true;
    while (nstd.arg(i)) |a| : (i += 1) {
        if (!first) _ = nstd.write(fd, " ");
        _ = nstd.write(fd, a);
        first = false;
    }
    _ = nstd.write(fd, "\n");
    nstd.close(fd);
}

// ---- mkdir -----------------------------------------------------------------

fn appletMkdir() void {
    var i: usize = 1;
    var any = false;
    while (nstd.argZ(i)) |path| : (i += 1) {
        any = true;
        if (nstd.mkdir(path) < 0) {
            nstd.print("mkdir: cannot create ");
            nstd.print(nstd.arg(i).?);
            nstd.print("\n");
        }
    }
    if (!any) nstd.print("usage: mkdir <dir>...\n");
}

// ---- cat -------------------------------------------------------------------

fn appletCat() void {
    if (nstd.argc() <= 1) {
        var buf: [256]u8 = undefined;
        while (true) {
            const n = nstd.read(0, &buf);
            if (n == 0) break;
            _ = nstd.write(1, buf[0..n]);
        }
        return;
    }
    var i: usize = 1;
    while (nstd.argZ(i)) |path| : (i += 1) {
        const fd_raw = nstd.open(path, 0);
        if (fd_raw < 0) {
            nstd.print("cat: cannot open ");
            nstd.print(nstd.arg(i).?);
            nstd.print("\n");
            continue;
        }
        const fd: usize = @intCast(fd_raw);
        var buf: [256]u8 = undefined;
        while (true) {
            const n = nstd.read(fd, &buf);
            if (n == 0) break;
            _ = nstd.write(1, buf[0..n]);
        }
        nstd.close(fd);
    }
}

// ---- ls --------------------------------------------------------------------

fn listDir(path: [*:0]const u8) void {
    const fd_raw = nstd.open(path, 0);
    if (fd_raw < 0) { nstd.print("ls: cannot open directory\n"); return; }
    const fd: usize = @intCast(fd_raw);
    var buf: [1024]u8 = undefined;
    while (true) {
        const n = nstd.getdents64(fd, &buf);
        if (n <= 0) break;
        var off: usize = 0;
        const total: usize = @intCast(n);
        while (off < total) {
            const reclen = std.mem.readInt(u16, buf[off + 16 .. off + 18][0..2], .little);
            const name_ptr: [*:0]const u8 = @ptrCast(&buf[off + 19]);
            var len: usize = 0;
            while (name_ptr[len] != 0) len += 1;
            nstd.print(name_ptr[0..len]);
            nstd.print("  ");
            off += reclen;
        }
    }
    nstd.print("\n");
    nstd.close(fd);
}

fn appletLs() void {
    if (nstd.argc() <= 1) {
        listDir(".");
    } else {
        var i: usize = 1;
        while (nstd.argZ(i)) |p| : (i += 1) listDir(p);
    }
}

// ---- wc --------------------------------------------------------------------

fn wcFd(fd: usize, out_lines: *usize, out_words: *usize, out_bytes: *usize) void {
    var buf: [512]u8 = undefined;
    var lines: usize = 0;
    var words: usize = 0;
    var bytes: usize = 0;
    var in_word = false;
    while (true) {
        const n = nstd.read(fd, &buf);
        if (n == 0) break;
        bytes += n;
        for (buf[0..n]) |c| {
            if (c == '\n') lines += 1;
            const ws = (c == ' ' or c == '\t' or c == '\n' or c == '\r');
            if (!ws and !in_word) { words += 1; in_word = true; }
            else if (ws) in_word = false;
        }
    }
    out_lines.* = lines;
    out_words.* = words;
    out_bytes.* = bytes;
}

fn printWc(lines: usize, words: usize, bytes: usize, name: ?[]const u8) void {
    nstd.printDec(lines);
    nstd.print(" ");
    nstd.printDec(words);
    nstd.print(" ");
    nstd.printDec(bytes);
    if (name) |n| { nstd.print(" "); nstd.print(n); }
    nstd.print("\n");
}

fn appletWc() void {
    if (nstd.argc() <= 1) {
        var l: usize = 0; var w: usize = 0; var b: usize = 0;
        wcFd(0, &l, &w, &b);
        printWc(l, w, b, null);
        return;
    }
    var tl: usize = 0; var tw: usize = 0; var tb: usize = 0;
    const multi = nstd.argc() > 2;
    var i: usize = 1;
    while (nstd.argZ(i)) |path| : (i += 1) {
        const fd_raw = nstd.open(path, 0);
        if (fd_raw < 0) {
            nstd.print("wc: cannot open "); nstd.print(nstd.arg(i).?); nstd.print("\n");
            continue;
        }
        var l: usize = 0; var w: usize = 0; var b: usize = 0;
        wcFd(@intCast(fd_raw), &l, &w, &b);
        nstd.close(@intCast(fd_raw));
        printWc(l, w, b, nstd.arg(i));
        tl += l; tw += w; tb += b;
    }
    if (multi) printWc(tl, tw, tb, "total");
}

// ---- grep ------------------------------------------------------------------

fn grepFd(fd: usize, pat: []const u8, prefix: ?[]const u8) void {
    var ibuf: [256]u8 = undefined;
    var line: [2048]u8 = undefined;
    var ll: usize = 0;
    while (true) {
        const n = nstd.read(fd, &ibuf);
        if (n == 0) {
            // flush partial line at EOF
            if (ll > 0 and std.mem.indexOf(u8, line[0..ll], pat) != null) {
                if (prefix) |p| { nstd.print(p); nstd.print(":"); }
                _ = nstd.write(1, line[0..ll]);
                nstd.print("\n");
            }
            break;
        }
        for (ibuf[0..n]) |c| {
            if (c == '\n') {
                if (std.mem.indexOf(u8, line[0..ll], pat) != null) {
                    if (prefix) |p| { nstd.print(p); nstd.print(":"); }
                    _ = nstd.write(1, line[0..ll]);
                    nstd.print("\n");
                }
                ll = 0;
            } else if (ll < line.len - 1) {
                line[ll] = c;
                ll += 1;
            }
        }
    }
}

fn appletGrep() void {
    if (nstd.argc() < 2) { nstd.print("usage: grep pattern [file...]\n"); return; }
    const pat = nstd.arg(1).?;
    if (nstd.argc() <= 2) {
        grepFd(0, pat, null);
        return;
    }
    const multi = nstd.argc() > 3;
    var i: usize = 2;
    while (nstd.argZ(i)) |path| : (i += 1) {
        const fd_raw = nstd.open(path, 0);
        if (fd_raw < 0) {
            nstd.print("grep: cannot open "); nstd.print(nstd.arg(i).?); nstd.print("\n");
            continue;
        }
        grepFd(@intCast(fd_raw), pat, if (multi) nstd.arg(i) else null);
        nstd.close(@intCast(fd_raw));
    }
}

// ---- head ------------------------------------------------------------------

fn headFd(fd: usize, n_lines: usize) void {
    var buf: [512]u8 = undefined;
    var count: usize = 0;
    var done = false;
    while (!done) {
        const n = nstd.read(fd, &buf);
        if (n == 0) break;
        var start: usize = 0;
        for (buf[0..n], 0..) |c, idx| {
            if (c == '\n') {
                _ = nstd.write(1, buf[start .. idx + 1]);
                start = idx + 1;
                count += 1;
                if (count >= n_lines) { done = true; break; }
            }
        }
        if (!done and start < n) _ = nstd.write(1, buf[start..n]);
    }
}

fn parseHeadN(start: *usize) usize {
    if (nstd.arg(1)) |a| {
        if (eq(a, "-n")) {
            // -n <N>
            const v = parseNat(nstd.arg(2) orelse "") orelse 10;
            start.* = 3;
            return v;
        }
        if (a.len > 2 and a[0] == '-' and a[1] == 'n') {
            // -n<N>
            const v = parseNat(a[2..]) orelse 10;
            start.* = 2;
            return v;
        }
    }
    return 10;
}

fn appletHead() void {
    var file_start: usize = 1;
    const n_lines = parseHeadN(&file_start);
    if (nstd.argc() <= file_start) {
        headFd(0, n_lines);
        return;
    }
    var i: usize = file_start;
    while (nstd.argZ(i)) |path| : (i += 1) {
        const fd_raw = nstd.open(path, 0);
        if (fd_raw < 0) {
            nstd.print("head: cannot open "); nstd.print(nstd.arg(i).?); nstd.print("\n");
            continue;
        }
        headFd(@intCast(fd_raw), n_lines);
        nstd.close(@intCast(fd_raw));
    }
}

// ---- tail ------------------------------------------------------------------
//
// Ring buffer: stores the last TAIL_N lines (up to TAIL_L bytes each).

const TAIL_N = 25;
const TAIL_L = 256;

fn tailFd(fd: usize, n_want: usize) void {
    // Ring buffer lives on the stack: 25 * 256 + 25 * 8 = 6400 + 200 bytes.
    var ring: [TAIL_N][TAIL_L]u8 = undefined;
    var rlen: [TAIL_N]usize = .{0} ** TAIL_N;
    var total: usize = 0; // total lines flushed into the ring

    var ibuf: [256]u8 = undefined;
    var cur: [TAIL_L]u8 = undefined;
    var cl: usize = 0;

    while (true) {
        const n = nstd.read(fd, &ibuf);
        if (n == 0) {
            // flush partial final line (no trailing newline)
            if (cl > 0) {
                const slot = total % TAIL_N;
                const len = @min(cl, TAIL_L);
                @memcpy(ring[slot][0..len], cur[0..len]);
                rlen[slot] = len;
                total += 1;
            }
            break;
        }
        for (ibuf[0..n]) |c| {
            if (c == '\n') {
                const slot = total % TAIL_N;
                const len = @min(cl, TAIL_L);
                @memcpy(ring[slot][0..len], cur[0..len]);
                rlen[slot] = len;
                total += 1;
                cl = 0;
            } else if (cl < TAIL_L - 1) {
                cur[cl] = c;
                cl += 1;
            }
        }
    }

    // Oldest slot in the ring.
    const have = @min(total, TAIL_N);
    const oldest: usize = if (total <= TAIL_N) 0 else total % TAIL_N;
    const n_lines = @min(n_want, TAIL_N);
    const skip: usize = if (have > n_lines) have - n_lines else 0;

    var i: usize = skip;
    while (i < have) : (i += 1) {
        const slot = (oldest + i) % TAIL_N;
        _ = nstd.write(1, ring[slot][0..rlen[slot]]);
        _ = nstd.write(1, "\n");
    }
}

fn appletTail() void {
    var file_start: usize = 1;
    const n_lines = parseHeadN(&file_start); // same -n parsing as head
    if (nstd.argc() <= file_start) {
        tailFd(0, n_lines);
        return;
    }
    var i: usize = file_start;
    while (nstd.argZ(i)) |path| : (i += 1) {
        const fd_raw = nstd.open(path, 0);
        if (fd_raw < 0) {
            nstd.print("tail: cannot open "); nstd.print(nstd.arg(i).?); nstd.print("\n");
            continue;
        }
        tailFd(@intCast(fd_raw), n_lines);
        nstd.close(@intCast(fd_raw));
    }
}

// ---- cp --------------------------------------------------------------------

fn appletCp() void {
    if (nstd.argc() < 3) { nstd.print("usage: cp src dst\n"); return; }
    const src = nstd.argZ(1).?;
    const dst = nstd.argZ(2).?;

    const sfd_raw = nstd.open(src, 0);
    if (sfd_raw < 0) { nstd.print("cp: cannot open source\n"); return; }
    const sfd: usize = @intCast(sfd_raw);

    const dfd_raw = nstd.open(dst, 0o100 | 0o1000); // O_CREAT | O_TRUNC
    if (dfd_raw < 0) {
        nstd.close(sfd);
        nstd.print("cp: cannot create dest\n");
        return;
    }
    const dfd: usize = @intCast(dfd_raw);

    var buf: [512]u8 = undefined;
    while (true) {
        const n = nstd.read(sfd, &buf);
        if (n == 0) break;
        _ = nstd.write(dfd, buf[0..n]);
    }
    nstd.close(sfd);
    nstd.close(dfd);
}

// ---- touch -----------------------------------------------------------------

fn appletTouch() void {
    if (nstd.argc() < 2) { nstd.print("usage: touch file...\n"); return; }
    var i: usize = 1;
    while (nstd.argZ(i)) |path| : (i += 1) {
        const fd_raw = nstd.open(path, 0o100); // O_CREAT, no truncate
        if (fd_raw < 0) {
            nstd.print("touch: cannot create ");
            nstd.print(nstd.arg(i).?);
            nstd.print("\n");
        } else {
            nstd.close(@intCast(fd_raw));
        }
    }
}

// ---- seq -------------------------------------------------------------------

fn appletSeq() void {
    var first: usize = 1;
    var step:  usize = 1;
    var last:  usize = 0;
    switch (nstd.argc() - 1) {
        1 => {
            last  = parseNat(nstd.arg(1) orelse "") orelse {
                nstd.print("seq: invalid argument\n"); return;
            };
        },
        2 => {
            first = parseNat(nstd.arg(1) orelse "") orelse {
                nstd.print("seq: invalid argument\n"); return;
            };
            last  = parseNat(nstd.arg(2) orelse "") orelse {
                nstd.print("seq: invalid argument\n"); return;
            };
        },
        3 => {
            first = parseNat(nstd.arg(1) orelse "") orelse {
                nstd.print("seq: invalid argument\n"); return;
            };
            step  = parseNat(nstd.arg(2) orelse "") orelse {
                nstd.print("seq: invalid argument\n"); return;
            };
            last  = parseNat(nstd.arg(3) orelse "") orelse {
                nstd.print("seq: invalid argument\n"); return;
            };
        },
        else => { nstd.print("usage: seq [first [step]] last\n"); return; },
    }
    if (step == 0) { nstd.print("seq: step cannot be zero\n"); return; }
    var v: usize = first;
    while (v <= last) : (v += step) {
        nstd.printDec(@as(u64, v));
        nstd.print("\n");
    }
}

// ---- tee -------------------------------------------------------------------

fn appletTee() void {
    var out_fd: ?usize = null;
    if (nstd.argZ(1)) |path| {
        const fd_raw = nstd.open(path, 0o100 | 0o1000); // O_CREAT | O_TRUNC
        if (fd_raw < 0) { nstd.print("tee: cannot open file\n"); return; }
        out_fd = @intCast(fd_raw);
    }
    var buf: [512]u8 = undefined;
    while (true) {
        const n = nstd.read(0, &buf);
        if (n == 0) break;
        _ = nstd.write(1, buf[0..n]);
        if (out_fd) |fd| _ = nstd.write(fd, buf[0..n]);
    }
    if (out_fd) |fd| nstd.close(fd);
}

// ---- true / false ----------------------------------------------------------

fn appletTrue()  void { nstd.exit(0); }
fn appletFalse() void { nstd.exit(1); }

// ---- uptime ----------------------------------------------------------------

fn printPad2(n: u64) void {
    if (n < 10) nstd.print("0");
    nstd.printDec(n);
}

fn appletUptime() void {
    const ticks = nstd.uptimeTicks();
    const secs  = ticks / 100;
    const days  = secs / 86400;
    const hours = (secs % 86400) / 3600;
    const mins  = (secs % 3600) / 60;
    const s     = secs % 60;

    nstd.print(" up ");
    if (days > 0) {
        nstd.printDec(days);
        nstd.print(if (days == 1) " day, " else " days, ");
    }
    printPad2(hours);
    nstd.print(":");
    printPad2(mins);
    nstd.print(":");
    printPad2(s);
    nstd.print("\n");
}

// ---- uname -----------------------------------------------------------------

fn appletUname() void {
    // Fields: sysname nodename release version machine
    const sysname = "Nevara";
    const nodename = "nevara";
    const release  = "0.1.0";
    const version  = "#1 SMP";
    const machine  = "x86_64";

    var all = false;
    var i: usize = 1;
    while (nstd.arg(i)) |a| : (i += 1) {
        if (std.mem.eql(u8, a, "-a")) all = true;
    }

    if (all) {
        nstd.print(sysname);  nstd.print(" ");
        nstd.print(nodename); nstd.print(" ");
        nstd.print(release);  nstd.print(" ");
        nstd.print(version);  nstd.print(" ");
        nstd.print(machine);  nstd.print("\n");
    } else {
        nstd.print(sysname);
        nstd.print("\n");
    }
}

// ---- nevfetch --------------------------------------------------------------
//
// ASCII art: a big N (16 chars wide) side-by-side with system info.
// Logo lines are all exactly 16 visible chars, padded with spaces.

// Print one row: [cyan logo] + [reset] + [info] + newline.
fn nfRow(logo: []const u8, info: []const u8) void {
    nstd.print("\x1b[1;36m"); nstd.print(logo);
    nstd.print("\x1b[0m  ");  nstd.print(info);
    nstd.print("\n");
}

// Print one row with a bold label + plain value.
fn nfLbl(logo: []const u8, label: []const u8, val: []const u8) void {
    nstd.print("\x1b[1;36m"); nstd.print(logo);
    nstd.print("\x1b[0m  \x1b[1m"); nstd.print(label);
    nstd.print("\x1b[0m"); nstd.print(val);
    nstd.print("\n");
}

// Format HH:MM:SS from jiffies (100 Hz) into buf[0..8].
fn nfFmtUptime(buf: *[16]u8) []const u8 {
    const ticks = nstd.uptimeTicks();
    const secs = ticks / 100;
    const h = (secs % 86400) / 3600;
    const m = (secs % 3600) / 60;
    const s = secs % 60;
    buf[0] = @as(u8, @intCast(h / 10)) + '0';
    buf[1] = @as(u8, @intCast(h % 10)) + '0';
    buf[2] = ':';
    buf[3] = @as(u8, @intCast(m / 10)) + '0';
    buf[4] = @as(u8, @intCast(m % 10)) + '0';
    buf[5] = ':';
    buf[6] = @as(u8, @intCast(s / 10)) + '0';
    buf[7] = @as(u8, @intCast(s % 10)) + '0';
    return buf[0..8];
}

fn appletNevfetch() void {
    // Each logo line is exactly 16 visible chars.
    // The "N" letter drawn with two verticals and a diagonal.
    const L0 = " |\\         |   ";  //  |\         |
    const L1 = " | \\        |   ";  //  | \        |
    const L2 = " |  \\       |   ";  //  |  \       |
    const L3 = " |   \\      |   ";  //  |   \      |
    const L4 = " |    \\     |   ";  //  |    \     |
    const L5 = " |     \\    |   ";  //  |     \    |
    const L6 = " |      \\   |   ";  //  |      \   |
    const L7 = " |       \\  |   ";  //  |       \  |
    const L8 = " |        \\ |   ";  //  |        \ |
    const L9 = " |         \\|   ";  //  |         \|
    const LB = "                ";  //  (blank)

    var ubuf: [16]u8 = undefined;
    const ustr = nfFmtUptime(&ubuf);

    nstd.print("\n");
    nfRow( L0, "\x1b[1mnevara\x1b[0m@\x1b[1mnevara\x1b[0m");
    nfRow( L1, "----------------------");
    nfLbl( L2, "OS:     ", "Nevara OS 0.1.0");
    nfLbl( L3, "Kernel: ", "Nevara 0.1.0 x86_64");
    nfLbl( L4, "Uptime: ", ustr);
    nfLbl( L5, "Shell:  ", "nsh");
    nfLbl( L6, "CPU:    ", "Intel x86_64");
    nfLbl( L7, "Memory: ", "512 MiB");
    nfLbl( L8, "Disk:   ", "ext4 /");
    nfRow( L9, "");
    nfRow( LB, "");
    // 8 normal colours
    nstd.print("  \x1b[40m   \x1b[41m   \x1b[42m   \x1b[43m   \x1b[44m   \x1b[45m   \x1b[46m   \x1b[47m   \x1b[0m\n");
    // 8 bright colours
    nstd.print("  \x1b[100m   \x1b[101m   \x1b[102m   \x1b[103m   \x1b[104m   \x1b[105m   \x1b[106m   \x1b[107m   \x1b[0m\n");
    nstd.print("\n");
}

// ============================================================================
// New applets: sort, uniq, cut, tr, rev, pwd, yes, basename, dirname, rm, mv, sleep
// ============================================================================

// ---- sort ------------------------------------------------------------------

fn sortCmpLines(content: []u8, as: usize, al: usize, bs: usize, bl: usize) isize {
    const min = @min(al, bl);
    var i: usize = 0;
    while (i < min) : (i += 1) {
        if (content[as + i] < content[bs + i]) return -1;
        if (content[as + i] > content[bs + i]) return  1;
    }
    if (al < bl) return -1;
    if (al > bl) return  1;
    return 0;
}

fn sortReadFd(fd: usize, content: []u8, starts: []usize, lens: []usize,
              used: *usize, count: *usize) void {
    var ibuf: [512]u8 = undefined;
    var line_start: usize = used.*;
    while (true) {
        const n = nstd.read(fd, &ibuf);
        if (n == 0) {
            if (used.* > line_start and count.* < starts.len) {
                starts[count.*] = line_start;
                lens[count.*]   = used.* - line_start;
                count.* += 1;
            }
            break;
        }
        for (ibuf[0..n]) |c| {
            if (c == '\n') {
                if (count.* < starts.len) {
                    starts[count.*] = line_start;
                    lens[count.*]   = used.* - line_start;
                    count.* += 1;
                }
                line_start = used.*;
            } else if (used.* < content.len) {
                content[used.*] = c;
                used.* += 1;
            }
        }
    }
}

fn appletSort() void {
    const a = nstd.allocator();
    const MAX_BYTES: usize = 65536;
    const MAX_LINES: usize = 4096;

    const content  = a.alloc(u8,    MAX_BYTES) catch { nstd.print("sort: out of memory\n"); return; };
    const starts   = a.alloc(usize, MAX_LINES) catch { nstd.print("sort: out of memory\n"); return; };
    const lens_arr = a.alloc(usize, MAX_LINES) catch { nstd.print("sort: out of memory\n"); return; };

    var rev_flag = false;
    var file_start: usize = 1;
    while (nstd.arg(file_start)) |f| {
        if (eq(f, "-r")) { rev_flag = true; file_start += 1; } else break;
    }

    var used:  usize = 0;
    var count: usize = 0;

    if (nstd.argc() <= file_start) {
        sortReadFd(0, content, starts, lens_arr, &used, &count);
    } else {
        var i: usize = file_start;
        while (nstd.argZ(i)) |path| : (i += 1) {
            const fd_raw = nstd.open(path, 0);
            if (fd_raw < 0) { nstd.print("sort: cannot open "); nstd.print(nstd.arg(i).?); nstd.print("\n"); continue; }
            sortReadFd(@intCast(fd_raw), content, starts, lens_arr, &used, &count);
            nstd.close(@intCast(fd_raw));
        }
    }

    // Insertion sort.
    var i: usize = 1;
    while (i < count) : (i += 1) {
        const ks = starts[i];
        const kl = lens_arr[i];
        var j: usize = i;
        while (j > 0) {
            const cmp = sortCmpLines(content, starts[j-1], lens_arr[j-1], ks, kl);
            const should_shift = if (rev_flag) cmp < 0 else cmp > 0;
            if (!should_shift) break;
            starts[j]   = starts[j-1];
            lens_arr[j] = lens_arr[j-1];
            j -= 1;
        }
        starts[j]   = ks;
        lens_arr[j] = kl;
    }

    for (0..count) |k| {
        _ = nstd.write(1, content[starts[k] .. starts[k] + lens_arr[k]]);
        _ = nstd.write(1, "\n");
    }
}

// ---- uniq ------------------------------------------------------------------

fn uniqFlush(line: []const u8, prev: *[2048]u8, prev_len: *usize, first: *bool) void {
    const same = !first.* and
        prev_len.* == line.len and
        std.mem.eql(u8, prev[0..prev_len.*], line);
    if (!same) {
        _ = nstd.write(1, line);
        _ = nstd.write(1, "\n");
        const n = @min(line.len, prev.len);
        @memcpy(prev[0..n], line[0..n]);
        prev_len.* = n;
    }
    first.* = false;
}

fn uniqFd(fd: usize, prev: *[2048]u8, prev_len: *usize, first: *bool) void {
    var ibuf: [256]u8 = undefined;
    var cur: [2048]u8 = undefined;
    var cl: usize = 0;
    while (true) {
        const n = nstd.read(fd, &ibuf);
        if (n == 0) {
            if (cl > 0) uniqFlush(cur[0..cl], prev, prev_len, first);
            break;
        }
        for (ibuf[0..n]) |c| {
            if (c == '\n') {
                uniqFlush(cur[0..cl], prev, prev_len, first);
                cl = 0;
            } else if (cl < cur.len - 1) {
                cur[cl] = c;
                cl += 1;
            }
        }
    }
}

fn appletUniq() void {
    var prev: [2048]u8 = undefined;
    var prev_len: usize = 0;
    var first = true;
    if (nstd.argc() <= 1) {
        uniqFd(0, &prev, &prev_len, &first);
    } else {
        var i: usize = 1;
        while (nstd.argZ(i)) |path| : (i += 1) {
            const fd_raw = nstd.open(path, 0);
            if (fd_raw < 0) { nstd.print("uniq: cannot open "); nstd.print(nstd.arg(i).?); nstd.print("\n"); continue; }
            uniqFd(@intCast(fd_raw), &prev, &prev_len, &first);
            nstd.close(@intCast(fd_raw));
        }
    }
}

// ---- cut -------------------------------------------------------------------

fn cutField(line: []const u8, delim: u8, field: usize) void {
    var f: usize = 1;
    var i: usize = 0;
    var start: usize = 0;
    while (i <= line.len) : (i += 1) {
        const boundary = (i == line.len) or (line[i] == delim);
        if (boundary) {
            if (f == field) {
                _ = nstd.write(1, line[start..i]);
                nstd.print("\n");
                return;
            }
            f += 1;
            start = i + 1;
        }
    }
    nstd.print("\n"); // field not found
}

fn cutFd(fd: usize, delim: u8, field: usize) void {
    var ibuf: [256]u8 = undefined;
    var line: [2048]u8 = undefined;
    var ll: usize = 0;
    while (true) {
        const n = nstd.read(fd, &ibuf);
        if (n == 0) { if (ll > 0) cutField(line[0..ll], delim, field); break; }
        for (ibuf[0..n]) |c| {
            if (c == '\n') { cutField(line[0..ll], delim, field); ll = 0; }
            else if (ll < line.len - 1) { line[ll] = c; ll += 1; }
        }
    }
}

fn appletCut() void {
    var delim: u8 = '\t';
    var field: usize = 1;
    var file_start: usize = 1;
    var i: usize = 1;
    while (nstd.arg(i)) |a| : (i += 1) {
        if (a.len >= 2 and a[0] == '-' and a[1] == 'd') {
            if (a.len > 2) delim = a[2]
            else if (nstd.arg(i + 1)) |d| { delim = if (d.len > 0) d[0] else '\t'; i += 1; }
        } else if (a.len >= 2 and a[0] == '-' and a[1] == 'f') {
            if (a.len > 2) field = parseNat(a[2..]) orelse 1
            else if (nstd.arg(i + 1)) |fn_| { field = parseNat(fn_) orelse 1; i += 1; }
        } else { file_start = i; break; }
        file_start = i + 1;
    }
    if (nstd.argc() <= file_start) {
        cutFd(0, delim, field);
    } else {
        var j: usize = file_start;
        while (nstd.argZ(j)) |path| : (j += 1) {
            const fd_raw = nstd.open(path, 0);
            if (fd_raw < 0) { nstd.print("cut: cannot open "); nstd.print(nstd.arg(j).?); nstd.print("\n"); continue; }
            cutFd(@intCast(fd_raw), delim, field);
            nstd.close(@intCast(fd_raw));
        }
    }
}

// ---- tr --------------------------------------------------------------------

fn appletTr() void {
    var delete_mode = false;
    var arg_start: usize = 1;

    if (nstd.arg(1)) |a| {
        if (eq(a, "-d")) { delete_mode = true; arg_start = 2; }
    }

    const set1 = nstd.arg(arg_start) orelse { nstd.print("usage: tr [-d] SET1 [SET2]\n"); return; };

    // Build 256-entry translation table (0xFF = delete).
    var table: [256]u8 = undefined;
    for (0..256) |k| table[k] = @intCast(k);

    if (delete_mode) {
        for (set1) |c| table[c] = 0xFF;
    } else {
        const set2 = nstd.arg(arg_start + 1) orelse { nstd.print("tr: missing SET2\n"); return; };
        const n = @min(set1.len, set2.len);
        for (0..n) |k| table[set1[k]] = set2[k];
        if (set1.len > set2.len and set2.len > 0) {
            for (set2.len..set1.len) |k| table[set1[k]] = set2[set2.len - 1];
        }
    }

    var ibuf: [512]u8 = undefined;
    while (true) {
        const n = nstd.read(0, &ibuf);
        if (n == 0) break;
        var obuf: [512]u8 = undefined;
        var o: usize = 0;
        for (ibuf[0..n]) |c| {
            const t = table[c];
            if (t != 0xFF) { obuf[o] = t; o += 1; }
        }
        if (o > 0) _ = nstd.write(1, obuf[0..o]);
    }
}

// ---- rev -------------------------------------------------------------------

fn revPrint(line: []u8) void {
    var lo: usize = 0;
    var hi: usize = line.len;
    while (lo < hi) {
        hi -= 1;
        const tmp = line[lo];
        line[lo] = line[hi];
        line[hi] = tmp;
        lo += 1;
    }
    _ = nstd.write(1, line);
    _ = nstd.write(1, "\n");
}

fn revFd(fd: usize) void {
    var ibuf: [256]u8 = undefined;
    var line: [2048]u8 = undefined;
    var ll: usize = 0;
    while (true) {
        const n = nstd.read(fd, &ibuf);
        if (n == 0) { if (ll > 0) revPrint(line[0..ll]); break; }
        for (ibuf[0..n]) |c| {
            if (c == '\n') { revPrint(line[0..ll]); ll = 0; }
            else if (ll < line.len - 1) { line[ll] = c; ll += 1; }
        }
    }
}

fn appletRev() void {
    if (nstd.argc() <= 1) {
        revFd(0);
    } else {
        var i: usize = 1;
        while (nstd.argZ(i)) |path| : (i += 1) {
            const fd_raw = nstd.open(path, 0);
            if (fd_raw < 0) { nstd.print("rev: cannot open "); nstd.print(nstd.arg(i).?); nstd.print("\n"); continue; }
            revFd(@intCast(fd_raw));
            nstd.close(@intCast(fd_raw));
        }
    }
}

// ---- pwd -------------------------------------------------------------------

fn appletPwd() void {
    var buf: [256]u8 = undefined;
    const n = nstd.getcwd(&buf);
    if (n > 1) {
        _ = nstd.write(1, buf[0..@intCast(n - 1)]);
        nstd.print("\n");
    } else {
        nstd.print("/\n");
    }
}

// ---- yes -------------------------------------------------------------------

fn appletYes() void {
    const s = nstd.arg(1) orelse "y";
    while (true) {
        nstd.print(s);
        nstd.print("\n");
    }
}

// ---- basename / dirname ----------------------------------------------------

fn appletBasename() void {
    const path = nstd.arg(1) orelse { nstd.print("usage: basename PATH [SUFFIX]\n"); return; };
    var start: usize = 0;
    for (path, 0..) |c, idx| if (c == '/') { start = idx + 1; };
    var base = path[start..];
    if (nstd.arg(2)) |suffix| {
        if (base.len >= suffix.len and
            std.mem.eql(u8, base[base.len - suffix.len ..], suffix))
        {
            base = base[0 .. base.len - suffix.len];
        }
    }
    nstd.print(base);
    nstd.print("\n");
}

fn appletDirname() void {
    const path = nstd.arg(1) orelse { nstd.print("usage: dirname PATH\n"); return; };
    if (std.mem.lastIndexOfScalar(u8, path, '/')) |pos| {
        if (pos == 0) nstd.print("/\n")
        else { nstd.print(path[0..pos]); nstd.print("\n"); }
    } else {
        nstd.print(".\n");
    }
}

// ---- rm / rm -r ------------------------------------------------------------

/// Recursively remove path (file or directory tree). Re-opens the directory
/// on each iteration to avoid invalidated offsets after child removal.
fn rmRecursive(path_str: []const u8, force: bool) void {
    // Build null-terminated copy for syscall wrappers.
    var pbuf: [512]u8 = undefined;
    if (path_str.len >= pbuf.len - 1) return;
    @memcpy(pbuf[0..path_str.len], path_str);
    pbuf[path_str.len] = 0;
    const path_z: [*:0]const u8 = @ptrCast(&pbuf);

    // Try file removal first.
    if (nstd.unlinkFile(path_z) == 0) return;

    // Not a file (or doesn't exist) — try treating it as a directory.
    // Remove children one at a time, re-reading each iteration.
    while (true) {
        const fd_raw = nstd.open(path_z, 0);
        if (fd_raw < 0) {
            if (!force) {
                nstd.print("rm: cannot access "); nstd.print(path_str); nstd.print("\n");
            }
            return;
        }
        var dbuf: [256]u8 = undefined;
        const n = nstd.getdents64(@intCast(fd_raw), &dbuf);
        nstd.close(@intCast(fd_raw));
        if (n <= 0) break; // directory is empty

        // Parse first entry from the dirent buffer.
        const name_ptr: [*:0]const u8 = @ptrCast(&dbuf[19]);
        var nlen: usize = 0;
        while (name_ptr[nlen] != 0) nlen += 1;

        // Build full child path and recurse.
        var child: [512]u8 = undefined;
        const clen = path_str.len + 1 + nlen;
        if (clen < child.len) {
            @memcpy(child[0..path_str.len], path_str);
            child[path_str.len] = '/';
            @memcpy(child[path_str.len + 1 .. path_str.len + 1 + nlen], name_ptr[0..nlen]);
            rmRecursive(child[0..clen], force);
        }
    }

    // Now directory should be empty — remove it.
    if (nstd.rmdirPath(path_z) < 0 and !force) {
        nstd.print("rm: cannot remove dir "); nstd.print(path_str); nstd.print("\n");
    }
}

fn appletRm() void {
    // Parse flags: -r/-R (recursive), -f (force), -rf/-fr/-Rf etc.
    var recursive = false;
    var force = false;
    var file_start: usize = 1;

    while (nstd.arg(file_start)) |a| {
        if (a.len >= 2 and a[0] == '-') {
            for (a[1..]) |c| switch (c) {
                'r', 'R' => recursive = true,
                'f'      => force     = true,
                else     => {},
            };
            file_start += 1;
        } else break;
    }

    if (nstd.argc() <= file_start) {
        nstd.print("usage: rm [-r] [-f] file...\n");
        return;
    }

    var i: usize = file_start;
    while (nstd.argZ(i)) |path| : (i += 1) {
        if (recursive) {
            rmRecursive(nstd.arg(i).?, force);
        } else {
            if (nstd.unlinkFile(path) < 0 and !force) {
                nstd.print("rm: cannot remove ");
                nstd.print(nstd.arg(i).?);
                nstd.print("\n");
            }
        }
    }
}

// ---- mv --------------------------------------------------------------------

fn appletMv() void {
    if (nstd.argc() < 3) { nstd.print("usage: mv src dst\n"); return; }
    const src = nstd.argZ(1).?;
    const dst = nstd.argZ(2).?;
    if (nstd.renameFile(src, dst) < 0) {
        nstd.print("mv: cannot rename ");
        nstd.print(std.mem.span(src));
        nstd.print("\n");
    }
}

// ---- sleep -----------------------------------------------------------------

fn appletSleep() void {
    const n = parseNat(nstd.arg(1) orelse "0") orelse 0;
    nstd.sleep(n);
}


// ---- chmod -----------------------------------------------------------------

fn appletChmod() void {
    if (nstd.argc() < 3) { nstd.print("usage: chmod MODE FILE...\n"); return; }
    const mode_str = nstd.arg(1).?;
    // Parse octal mode string (e.g. "755", "644").
    var mode: usize = 0;
    for (mode_str) |c| {
        if (c < '0' or c > '7') { nstd.print("chmod: invalid mode\n"); return; }
        mode = mode * 8 + (c - '0');
    }
    var i: usize = 2;
    while (nstd.argZ(i)) |path| : (i += 1) {
        if (nstd.chmodFile(path, mode) < 0) {
            nstd.print("chmod: cannot change ");
            nstd.print(nstd.arg(i).?);
            nstd.print("\n");
        }
    }
}

// ---- find ------------------------------------------------------------------
// find [dir] [-name pattern] [-type f|d] [-maxdepth N]
// Walks the directory tree rooted at dir (default: ".") and prints matching paths.

const FindOpts = struct {
    name_pat: ?[]const u8 = null,
    type_filter: u8 = 0, // 0=any 'f'=file 'd'=dir
    maxdepth: usize = 255,
};

fn findMatch(name: []const u8, pat: []const u8) bool {
    // Minimal glob: only '*' supported as multi-char wildcard.
    var pi: usize = 0;
    var ni: usize = 0;
    var star_pi: usize = 0;
    var star_ni: usize = 0;
    var has_star = false;
    while (ni < name.len) {
        if (pi < pat.len and pat[pi] == '*') {
            has_star = true;
            star_pi = pi;
            star_ni = ni;
            pi += 1;
        } else if (pi < pat.len and (pat[pi] == '?' or pat[pi] == name[ni])) {
            pi += 1;
            ni += 1;
        } else if (has_star) {
            star_ni += 1;
            ni = star_ni;
            pi = star_pi + 1;
        } else {
            return false;
        }
    }
    while (pi < pat.len and pat[pi] == '*') pi += 1;
    return pi == pat.len;
}

// dtype in linux dirent64: 4=dir, 8=file, 10=symlink, 0=unknown
fn findWalk(path_buf: []u8, path_len: usize, opts: *const FindOpts, depth: usize) void {
    if (depth > opts.maxdepth) return;
    path_buf[path_len] = 0;
    const dir_path: [*:0]const u8 = @ptrCast(path_buf.ptr);
    const fd_raw = nstd.open(dir_path, 0);
    if (fd_raw < 0) return;
    const fd: usize = @intCast(fd_raw);

    var buf: [2048]u8 = undefined;
    while (true) {
        const n = nstd.getdents64(fd, &buf);
        if (n <= 0) break;
        var off: usize = 0;
        const total: usize = @intCast(n);
        while (off < total) {
            const reclen = std.mem.readInt(u16, buf[off + 16 .. off + 18][0..2], .little);
            const dtype = buf[off + 18];
            const name_ptr: [*:0]const u8 = @ptrCast(&buf[off + 19]);
            var nlen: usize = 0;
            while (name_ptr[nlen] != 0) nlen += 1;
            const name = name_ptr[0..nlen];

            // Skip . and ..
            if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) {
                off += reclen;
                continue;
            }

            // Build full path in path_buf.
            var entry_len = path_len;
            if (entry_len > 0 and path_buf[entry_len - 1] != '/') {
                path_buf[entry_len] = '/';
                entry_len += 1;
            }
            const space = path_buf.len - entry_len - 1;
            const copy_len = if (nlen < space) nlen else space;
            @memcpy(path_buf[entry_len..entry_len + copy_len], name[0..copy_len]);
            const full_len = entry_len + copy_len;

            // Check type filter.
            const is_dir = (dtype == 4);
            const type_ok = opts.type_filter == 0 or
                (opts.type_filter == 'f' and !is_dir) or
                (opts.type_filter == 'd' and is_dir);

            // Check name pattern.
            const name_ok = if (opts.name_pat) |p| findMatch(name, p) else true;

            if (type_ok and name_ok) {
                _ = nstd.write(1, path_buf[0..full_len]);
                nstd.print("\n");
            }

            // Recurse into directories.
            if (is_dir) {
                findWalk(path_buf, full_len, opts, depth + 1);
            }

            // Restore path_buf.
            path_buf[path_len] = 0;
            off += reclen;
        }
    }
    nstd.close(fd);
}

fn appletFind() void {
    var opts = FindOpts{};
    var root: []const u8 = ".";
    var i: usize = 1;
    while (nstd.arg(i)) |a| : (i += 1) {
        if (eq(a, "-name")) {
            i += 1;
            opts.name_pat = nstd.arg(i) orelse "";
        } else if (eq(a, "-type")) {
            i += 1;
            if (nstd.arg(i)) |t| {
                if (t.len > 0) opts.type_filter = t[0];
            }
        } else if (eq(a, "-maxdepth")) {
            i += 1;
            if (nstd.arg(i)) |d| opts.maxdepth = parseNat(d) orelse 255;
        } else {
            root = a;
        }
    }
    var path_buf: [512]u8 = undefined;
    const rlen = if (root.len < path_buf.len - 1) root.len else path_buf.len - 2;
    @memcpy(path_buf[0..rlen], root[0..rlen]);
    findWalk(&path_buf, rlen, &opts, 0);
}

// ---- stat ------------------------------------------------------------------
// stat <file...> — print inode number, size, and type from getdents of parent.
// (We have no stat syscall, so we use a directory scan of the parent.)

fn appletStat() void {
    if (nstd.argc() < 2) { nstd.print("usage: stat <file...>\n"); return; }
    var i: usize = 1;
    while (nstd.argZ(i)) |path| : (i += 1) {
        const p = nstd.arg(i).?;
        // Try opening as directory first to determine type.
        const fd_raw = nstd.open(path, 0);
        if (fd_raw < 0) {
            nstd.print("stat: cannot open: "); nstd.print(p); nstd.print("\n");
            continue;
        }
        const fd: usize = @intCast(fd_raw);
        // Try getdents to probe if it's a directory.
        var probe: [64]u8 = undefined;
        const gd = nstd.getdents64(fd, &probe);
        const is_dir = gd > 0;
        // Get size via lseek to end.
        _ = nstd.lseek(fd, 0, 0);
        const size = nstd.lseek(fd, 0, 2);
        nstd.close(fd);

        nstd.print("  File: "); nstd.print(p); nstd.print("\n");
        nstd.print("  Type: ");
        if (is_dir) nstd.print("directory") else nstd.print("regular file");
        nstd.print("\n");
        if (!is_dir) {
            nstd.print("  Size: ");
            nstd.printDec(if (size >= 0) @intCast(size) else 0);
            nstd.print("\n");
        }
    }
}

// ---- strings ---------------------------------------------------------------
// strings [-n min] [file...] — print runs of ≥N printable ASCII chars.

fn stringsFd(fd: usize, min_len: usize) void {
    var buf: [512]u8 = undefined;
    var run: [256]u8 = undefined;
    var rlen: usize = 0;
    while (true) {
        const n = nstd.read(fd, &buf);
        if (n == 0) break;
        for (buf[0..n]) |c| {
            const printable = (c >= 0x20 and c <= 0x7E);
            if (printable) {
                if (rlen < run.len - 1) { run[rlen] = c; rlen += 1; }
            } else {
                if (rlen >= min_len) { _ = nstd.write(1, run[0..rlen]); nstd.print("\n"); }
                rlen = 0;
            }
        }
    }
    if (rlen >= min_len) { _ = nstd.write(1, run[0..rlen]); nstd.print("\n"); }
}

fn appletStrings() void {
    var min_len: usize = 4;
    var i: usize = 1;
    if (nstd.arg(i)) |a| {
        if (eq(a, "-n")) {
            i += 1;
            min_len = parseNat(nstd.arg(i) orelse "4") orelse 4;
            i += 1;
        }
    }
    if (nstd.argc() <= i) {
        stringsFd(0, min_len);
        return;
    }
    while (nstd.argZ(i)) |path| : (i += 1) {
        const fd_raw = nstd.open(path, 0);
        if (fd_raw < 0) { nstd.print("strings: cannot open "); nstd.print(nstd.arg(i).?); nstd.print("\n"); continue; }
        stringsFd(@intCast(fd_raw), min_len);
        nstd.close(@intCast(fd_raw));
    }
}

// ---- fold ------------------------------------------------------------------
// fold [-w width] [file...] — wrap long lines at width (default 80).

fn foldFd(fd: usize, width: usize) void {
    var buf: [512]u8 = undefined;
    var col: usize = 0;
    while (true) {
        const n = nstd.read(fd, &buf);
        if (n == 0) break;
        for (buf[0..n]) |c| {
            if (c == '\n') {
                _ = nstd.write(1, "\n");
                col = 0;
            } else {
                if (col >= width) {
                    _ = nstd.write(1, "\n");
                    col = 0;
                }
                var ch = [1]u8{c};
                _ = nstd.write(1, &ch);
                col += 1;
            }
        }
    }
}

fn appletFold() void {
    var width: usize = 80;
    var i: usize = 1;
    if (nstd.arg(i)) |a| {
        if (eq(a, "-w")) {
            i += 1;
            width = parseNat(nstd.arg(i) orelse "80") orelse 80;
            i += 1;
        }
    }
    if (nstd.argc() <= i) { foldFd(0, width); return; }
    while (nstd.argZ(i)) |path| : (i += 1) {
        const fd_raw = nstd.open(path, 0);
        if (fd_raw < 0) { nstd.print("fold: cannot open "); nstd.print(nstd.arg(i).?); nstd.print("\n"); continue; }
        foldFd(@intCast(fd_raw), width);
        nstd.close(@intCast(fd_raw));
    }
}

// ---- comm ------------------------------------------------------------------
// comm file1 file2 — compare two sorted files line by line.
// Output: col1=only-in-file1  col2=only-in-file2  col3=both

fn readLine(fd: usize, buf: []u8) usize {
    var i: usize = 0;
    while (i < buf.len - 1) {
        var c: [1]u8 = undefined;
        const n = nstd.read(fd, &c);
        if (n == 0) break;
        buf[i] = c[0];
        i += 1;
        if (c[0] == '\n') break;
    }
    return i;
}

fn appletComm() void {
    if (nstd.argc() < 3) { nstd.print("usage: comm file1 file2\n"); return; }
    const fd1_raw = nstd.open(nstd.argZ(1).?, 0);
    const fd2_raw = nstd.open(nstd.argZ(2).?, 0);
    if (fd1_raw < 0 or fd2_raw < 0) { nstd.print("comm: cannot open file\n"); return; }
    const fd1: usize = @intCast(fd1_raw);
    const fd2: usize = @intCast(fd2_raw);

    var l1: [1024]u8 = undefined;
    var l2: [1024]u8 = undefined;
    var n1 = readLine(fd1, &l1);
    var n2 = readLine(fd2, &l2);

    while (n1 > 0 or n2 > 0) {
        const s1 = trimNl(l1[0..n1]);
        const s2 = trimNl(l2[0..n2]);
        if (n1 == 0) {
            nstd.print("\t\t"); _ = nstd.write(1, s2); nstd.print("\n");
            n2 = readLine(fd2, &l2);
        } else if (n2 == 0) {
            _ = nstd.write(1, s1); nstd.print("\n");
            n1 = readLine(fd1, &l1);
        } else {
            const cmp = std.mem.order(u8, s1, s2);
            switch (cmp) {
                .lt => { _ = nstd.write(1, s1); nstd.print("\n"); n1 = readLine(fd1, &l1); },
                .gt => { nstd.print("\t"); _ = nstd.write(1, s2); nstd.print("\n"); n2 = readLine(fd2, &l2); },
                .eq => {
                    nstd.print("\t\t"); _ = nstd.write(1, s1); nstd.print("\n");
                    n1 = readLine(fd1, &l1);
                    n2 = readLine(fd2, &l2);
                },
            }
        }
    }
    nstd.close(fd1);
    nstd.close(fd2);
}

fn trimNl(s: []const u8) []const u8 {
    if (s.len > 0 and s[s.len - 1] == '\n') return s[0..s.len - 1];
    return s;
}

// ---- printf ----------------------------------------------------------------
// printf format [args...] — shell-style printf: %s %d %x \n \t

fn appletPrintf() void {
    const fmt = nstd.arg(1) orelse { nstd.print("usage: printf format [args...]\n"); return; };
    var ai: usize = 2; // index into argv for next arg
    var i: usize = 0;
    while (i < fmt.len) : (i += 1) {
        if (fmt[i] == '\\' and i + 1 < fmt.len) {
            i += 1;
            switch (fmt[i]) {
                'n'  => nstd.print("\n"),
                't'  => nstd.print("\t"),
                'r'  => nstd.print("\r"),
                '\\' => nstd.print("\\"),
                '0'  => { var b = [1]u8{0}; _ = nstd.write(1, &b); },
                else => { nstd.print("\\"); var b = [1]u8{fmt[i]}; _ = nstd.write(1, &b); },
            }
        } else if (fmt[i] == '%' and i + 1 < fmt.len) {
            i += 1;
            const arg = nstd.arg(ai) orelse "";
            ai += 1;
            switch (fmt[i]) {
                's' => nstd.print(arg),
                'd' => {
                    var neg = false;
                    var start: usize = 0;
                    if (arg.len > 0 and arg[0] == '-') { neg = true; start = 1; }
                    const v = parseNat(arg[start..]) orelse 0;
                    if (neg) nstd.print("-");
                    nstd.printDec(v);
                },
                'x' => {
                    const v = parseNat(arg) orelse 0;
                    printHex(v);
                },
                'o' => {
                    const v = parseNat(arg) orelse 0;
                    printOct(v);
                },
                '%' => { nstd.print("%"); ai -= 1; },
                else => { nstd.print("%"); var b = [1]u8{fmt[i]}; _ = nstd.write(1, &b); ai -= 1; },
            }
        } else {
            var b = [1]u8{fmt[i]};
            _ = nstd.write(1, &b);
        }
    }
}

fn printHex(v: usize) void {
    const digits = "0123456789abcdef";
    if (v == 0) { nstd.print("0"); return; }
    var buf: [16]u8 = undefined;
    var i: usize = buf.len;
    var n = v;
    while (n > 0) : (n >>= 4) { i -= 1; buf[i] = digits[n & 0xF]; }
    _ = nstd.write(1, buf[i..]);
}

fn printOct(v: usize) void {
    if (v == 0) { nstd.print("0"); return; }
    var buf: [22]u8 = undefined;
    var i: usize = buf.len;
    var n = v;
    while (n > 0) : (n >>= 3) { i -= 1; buf[i] = '0' + @as(u8, @intCast(n & 7)); }
    _ = nstd.write(1, buf[i..]);
}

// ---- which -----------------------------------------------------------------
// which cmd... — search PATH for cmd; we have a fixed set in /bin.

fn appletWhich() void {
    if (nstd.argc() < 2) { nstd.print("usage: which cmd...\n"); return; }
    var i: usize = 1;
    while (nstd.arg(i)) |cmd| : (i += 1) {
        var path_buf: [128]u8 = undefined;
        // Build "/bin/<cmd>"
        const prefix = "/bin/";
        @memcpy(path_buf[0..prefix.len], prefix);
        const clen = if (cmd.len < path_buf.len - prefix.len - 1) cmd.len else path_buf.len - prefix.len - 2;
        @memcpy(path_buf[prefix.len..prefix.len + clen], cmd[0..clen]);
        path_buf[prefix.len + clen] = 0;
        const cpath: [*:0]const u8 = @ptrCast(&path_buf);
        const fd = nstd.open(cpath, 0);
        if (fd >= 0) {
            nstd.close(@intCast(fd));
            nstd.print("/bin/"); nstd.print(cmd); nstd.print("\n");
        } else {
            nstd.print("which: not found: "); nstd.print(cmd); nstd.print("\n");
        }
    }
}

// ---- xargs -----------------------------------------------------------------
// xargs [cmd [initial-args]] — read NUL/newline-separated args from stdin
// and run cmd with batches of args.

fn appletXargs() void {
    // Collect command + its initial args.
    var cmd_buf: [64]u8 = undefined;
    var cmd_args: [32]?[*:0]const u8 = undefined;
    var cmd_argc: usize = 0;

    if (nstd.argc() < 2) {
        // default command is echo
        cmd_buf[0] = 0;
        const default_cmd: [*:0]const u8 = "/bin/echo";
        cmd_args[0] = default_cmd;
        cmd_argc = 1;
    } else {
        const prefix = "/bin/";
        const name = nstd.arg(1).?;
        @memcpy(cmd_buf[0..prefix.len], prefix);
        const nlen = if (name.len < cmd_buf.len - prefix.len - 1) name.len else cmd_buf.len - prefix.len - 2;
        @memcpy(cmd_buf[prefix.len..prefix.len + nlen], name[0..nlen]);
        cmd_buf[prefix.len + nlen] = 0;
        cmd_args[0] = @ptrCast(&cmd_buf);
        cmd_argc = 1;
        var ai: usize = 2;
        while (nstd.argZ(ai)) |a| : (ai += 1) {
            if (cmd_argc < cmd_args.len - 2) {
                cmd_args[cmd_argc] = a;
                cmd_argc += 1;
            }
        }
    }

    // Read stdin tokens (newline-separated).
    var tok_storage: [4096]u8 = undefined;
    var tok_len: usize = 0;
    var tokens: [64][*:0]const u8 = undefined;
    var tok_count: usize = 0;
    var tok_start: usize = 0;

    var ibuf: [256]u8 = undefined;
    while (true) {
        const n = nstd.read(0, &ibuf);
        if (n == 0) break;
        for (ibuf[0..n]) |c| {
            if (c == '\n' or c == ' ' or c == '\t' or c == 0) {
                if (tok_len > tok_start) {
                    tok_storage[tok_len] = 0;
                    tokens[tok_count] = @ptrCast(tok_storage[tok_start..].ptr);
                    tok_count += 1;
                    tok_start = tok_len + 1;
                    tok_len = tok_start;
                }
            } else if (tok_len < tok_storage.len - 1) {
                tok_storage[tok_len] = c;
                tok_len += 1;
            }
        }
    }
    if (tok_len > tok_start) {
        tok_storage[tok_len] = 0;
        tokens[tok_count] = @ptrCast(tok_storage[tok_start..].ptr);
        tok_count += 1;
    }

    if (tok_count == 0) return;

    // Build final argv.
    var argv: [96]?[*:0]const u8 = undefined;
    for (0..cmd_argc) |k| argv[k] = cmd_args[k];
    for (0..tok_count) |k| argv[cmd_argc + k] = tokens[k];
    argv[cmd_argc + tok_count] = null;

    const cmd_path: [*:0]const u8 = cmd_args[0].?;
    _ = nstd.spawn(cmd_path, @ptrCast(&argv));
}

// ---- ln --------------------------------------------------------------------
// ln [-s] target linkname — create a hard link (we do rename as a workaround:
// true hardlinks need a syscall we don't have; just cp for now).

fn appletLn() void {
    var i: usize = 1;
    // -s flag accepted but ignored (symlinks not yet in vfs; fall back to cp)
    if (nstd.arg(i)) |a| { if (eq(a, "-s")) i += 1; }
    const target = nstd.argZ(i) orelse { nstd.print("usage: ln [-s] target linkname\n"); return; };
    i += 1;
    const linkname = nstd.argZ(i) orelse { nstd.print("ln: missing linkname\n"); return; };
    // Copy target → linkname (best-effort).
    const fd_src = nstd.open(target, 0);
    if (fd_src < 0) { nstd.print("ln: cannot open target\n"); return; }
    const fd_dst_raw = nstd.open(linkname, 0o100 | 0o1000); // O_CREAT|O_TRUNC
    if (fd_dst_raw < 0) { nstd.close(@intCast(fd_src)); nstd.print("ln: cannot create link\n"); return; }
    var buf: [512]u8 = undefined;
    while (true) {
        const n = nstd.read(@intCast(fd_src), &buf);
        if (n == 0) break;
        _ = nstd.write(@intCast(fd_dst_raw), buf[0..n]);
    }
    nstd.close(@intCast(fd_src));
    nstd.close(@intCast(fd_dst_raw));
}

// ---- env -------------------------------------------------------------------
// env — print all environment variables.
// We don't have getenv, but we can print argv[0]..argvN looking for VAR=val.
// In Nevara, environment is not passed — just print a stub.

fn appletEnv() void {
    // nsh doesn't pass a real envp; print a minimal synthetic environment.
    nstd.print("PATH=/bin\n");
    nstd.print("HOME=/root\n");
    nstd.print("TERM=vt100\n");
    nstd.print("SHELL=/bin/nsh\n");
}

// ---- dd --------------------------------------------------------------------
// dd [if=file] [of=file] [bs=N] [count=N] [skip=N] [seek=N]

fn appletDd() void {
    var in_path: ?[*:0]const u8 = null;
    var out_path: ?[*:0]const u8 = null;
    var bs: usize = 512;
    var count: usize = 0xFFFF_FFFF;
    var skip: usize = 0;
    var seek: usize = 0;

    var i: usize = 1;
    while (nstd.arg(i)) |a| : (i += 1) {
        if (std.mem.startsWith(u8, a, "if="))    in_path  = nstd.argZ(i).? + 3
        else if (std.mem.startsWith(u8, a, "of=")) out_path = nstd.argZ(i).? + 3
        else if (std.mem.startsWith(u8, a, "bs=")) bs = parseNat(a[3..]) orelse 512
        else if (std.mem.startsWith(u8, a, "count=")) count = parseNat(a[6..]) orelse 0
        else if (std.mem.startsWith(u8, a, "skip="))  skip  = parseNat(a[5..]) orelse 0
        else if (std.mem.startsWith(u8, a, "seek="))  seek  = parseNat(a[5..]) orelse 0;
    }

    const fd_in: usize = if (in_path) |p| blk: {
        const fd = nstd.open(p, 0);
        if (fd < 0) { nstd.print("dd: cannot open input\n"); return; }
        break :blk @intCast(fd);
    } else 0;

    const fd_out: usize = if (out_path) |p| blk: {
        const fd = nstd.open(p, 0o100 | 0o1000);
        if (fd < 0) {
            if (in_path != null) nstd.close(fd_in);
            nstd.print("dd: cannot open output\n");
            return;
        }
        break :blk @intCast(fd);
    } else 1;

    // Skip input blocks.
    if (skip > 0) _ = nstd.lseek(fd_in, @intCast(skip * bs), 0);
    if (seek > 0) _ = nstd.lseek(fd_out, @intCast(seek * bs), 0);

    var buf = nstd.allocator().alloc(u8, bs) catch {
        nstd.print("dd: alloc failed\n");
        return;
    };

    var blocks: usize = 0;
    var total_bytes: usize = 0;
    while (blocks < count) : (blocks += 1) {
        const n = nstd.read(fd_in, buf);
        if (n == 0) break;
        _ = nstd.write(fd_out, buf[0..n]);
        total_bytes += n;
    }

    if (in_path != null) nstd.close(fd_in);
    if (out_path != null) nstd.close(fd_out);

    nstd.printDec(blocks); nstd.print("+0 records in\n");
    nstd.printDec(blocks); nstd.print("+0 records out\n");
    nstd.printDec(total_bytes); nstd.print(" bytes transferred\n");
}

// ---- od --------------------------------------------------------------------
// od [-x|-o|-c] [file] — octal/hex dump

fn appletOd() void {
    var fmt_char: u8 = 'o'; // 'o'=octal 'x'=hex 'c'=chars
    var i: usize = 1;
    if (nstd.arg(i)) |a| {
        if (eq(a, "-x")) { fmt_char = 'x'; i += 1; }
        else if (eq(a, "-o")) { fmt_char = 'o'; i += 1; }
        else if (eq(a, "-c")) { fmt_char = 'c'; i += 1; }
    }

    const fd: usize = if (nstd.argZ(i)) |p| blk: {
        const fd_raw = nstd.open(p, 0);
        if (fd_raw < 0) { nstd.print("od: cannot open\n"); return; }
        break :blk @intCast(fd_raw);
    } else 0;

    var buf: [16]u8 = undefined;
    var offset: usize = 0;
    while (true) {
        const n = nstd.read(fd, &buf);
        if (n == 0) break;
        // Print offset.
        printOct(offset);
        nstd.print(" ");
        offset += n;
        for (buf[0..n]) |c| {
            nstd.print(" ");
            switch (fmt_char) {
                'x' => { if (c < 0x10) nstd.print("0"); printHex(c); },
                'c' => {
                    if (c >= 0x20 and c <= 0x7E) {
                        var b = [1]u8{c}; _ = nstd.write(1, &b);
                    } else { nstd.print("."); }
                },
                else => printOct(c),
            }
        }
        nstd.print("\n");
    }
    printOct(offset); nstd.print("\n");
    if (fd != 0) nstd.close(fd);
}

// ---- nl --------------------------------------------------------------------
// nl [file...] — number lines

fn nlFd(fd: usize, counter: *usize) void {
    var ibuf: [256]u8 = undefined;
    var line: [2048]u8 = undefined;
    var ll: usize = 0;
    while (true) {
        const n = nstd.read(fd, &ibuf);
        if (n == 0) {
            if (ll > 0) {
                counter.* += 1;
                nstd.printDec(counter.*); nstd.print("\t");
                _ = nstd.write(1, line[0..ll]); nstd.print("\n");
            }
            break;
        }
        for (ibuf[0..n]) |c| {
            if (c == '\n') {
                counter.* += 1;
                nstd.printDec(counter.*); nstd.print("\t");
                _ = nstd.write(1, line[0..ll]); nstd.print("\n");
                ll = 0;
            } else if (ll < line.len - 1) {
                line[ll] = c; ll += 1;
            }
        }
    }
}

fn appletNl() void {
    var counter: usize = 0;
    if (nstd.argc() <= 1) { nlFd(0, &counter); return; }
    var i: usize = 1;
    while (nstd.argZ(i)) |path| : (i += 1) {
        const fd_raw = nstd.open(path, 0);
        if (fd_raw < 0) { nstd.print("nl: cannot open "); nstd.print(nstd.arg(i).?); nstd.print("\n"); continue; }
        nlFd(@intCast(fd_raw), &counter);
        nstd.close(@intCast(fd_raw));
    }
}

// ---- du --------------------------------------------------------------------
// du [-s] [file...] — disk usage in KiB (approximated via file size)

fn duPath(path: []u8, summarize: bool, depth: usize) usize {
    path[path.len] = 0; // ensure NUL
    const cpath: [*:0]const u8 = @ptrCast(path.ptr);
    const fd_raw = nstd.open(cpath, 0);
    if (fd_raw < 0) return 0;
    const fd: usize = @intCast(fd_raw);

    // Check if directory via getdents.
    var probe: [128]u8 = undefined;
    const gd = nstd.getdents64(fd, &probe);
    if (gd <= 0) {
        // Regular file — get size.
        _ = nstd.lseek(fd, 0, 0);
        const sz = nstd.lseek(fd, 0, 2);
        nstd.close(fd);
        const kib: usize = if (sz > 0) (@as(usize, @intCast(sz)) + 1023) / 1024 else 0;
        if (!summarize or depth == 0) {
            nstd.printDec(kib); nstd.print("\t"); _ = nstd.write(1, path[0..path.len]); nstd.print("\n");
        }
        return kib;
    }

    // Directory — recurse.
    var total: usize = 0;
    _ = nstd.lseek(fd, 0, 0);
    var dbuf: [2048]u8 = undefined;
    while (true) {
        const n = nstd.getdents64(fd, &dbuf);
        if (n <= 0) break;
        var off: usize = 0;
        const tot: usize = @intCast(n);
        while (off < tot) {
            const reclen = std.mem.readInt(u16, dbuf[off + 16 .. off + 18][0..2], .little);
            const name_ptr: [*:0]const u8 = @ptrCast(&dbuf[off + 19]);
            var nlen: usize = 0;
            while (name_ptr[nlen] != 0) nlen += 1;
            const name = name_ptr[0..nlen];
            if (!std.mem.eql(u8, name, ".") and !std.mem.eql(u8, name, "..")) {
                // Build child path.
                var child: [512]u8 = undefined;
                const base_len = path.len;
                @memcpy(child[0..base_len], path[0..base_len]);
                child[base_len] = '/';
                const clen = if (nlen < child.len - base_len - 2) nlen else child.len - base_len - 3;
                @memcpy(child[base_len + 1..base_len + 1 + clen], name[0..clen]);
                total += duPath(child[0..base_len + 1 + clen], summarize, depth + 1);
            }
            off += reclen;
        }
    }
    nstd.close(fd);

    if (!summarize or depth == 0) {
        nstd.printDec(total); nstd.print("\t"); _ = nstd.write(1, path[0..path.len]); nstd.print("\n");
    }
    return total;
}

fn appletDu() void {
    var summarize = false;
    var i: usize = 1;
    if (nstd.arg(i)) |a| {
        if (eq(a, "-s")) { summarize = true; i += 1; }
    }
    if (nstd.argc() <= i) {
        var buf: [4]u8 = undefined;
        buf[0] = '.'; buf[1] = 0;
        _ = duPath(buf[0..1], summarize, 0);
        return;
    }
    while (nstd.arg(i)) |a| : (i += 1) {
        var buf: [512]u8 = undefined;
        const alen = if (a.len < buf.len - 1) a.len else buf.len - 2;
        @memcpy(buf[0..alen], a[0..alen]);
        _ = duPath(buf[0..alen], summarize, 0);
    }
}
