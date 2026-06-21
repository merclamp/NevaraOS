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
    else nstd.print("nevbox: applets: echo cat ls mkfile mkdir " ++
                    "wc grep head tail cp touch seq tee true false " ++
                    "uptime uname nevfetch sort uniq cut tr rev " ++
                    "pwd yes basename dirname rm mv sleep\n");

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
