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
    else nstd.print("nevbox: applets: echo cat ls mkfile mkdir " ++
                    "wc grep head tail cp touch seq tee true false " ++
                    "uptime uname nevfetch\n");

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
    nfLbl( L8, "Disk:   ", "FAT16 /mnt  ext4 /ext");
    nfRow( L9, "");
    nfRow( LB, "");
    // 8 normal colours
    nstd.print("  \x1b[40m   \x1b[41m   \x1b[42m   \x1b[43m   \x1b[44m   \x1b[45m   \x1b[46m   \x1b[47m   \x1b[0m\n");
    // 8 bright colours
    nstd.print("  \x1b[100m   \x1b[101m   \x1b[102m   \x1b[103m   \x1b[104m   \x1b[105m   \x1b[106m   \x1b[107m   \x1b[0m\n");
    nstd.print("\n");
}
