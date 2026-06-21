//! ZLibc — Nevara's own minimal C standard library, written in Zig.
//!
//! NOT musl-ABI compatible: it exists so Nevara can compile its own C sources
//! against a small, all-Zig libc — not to run prebuilt Linux binaries. It sits
//! directly on the kernel syscall ABI; no external dependencies.

const SYS_read:      usize = 0;
const SYS_write:     usize = 1;
const SYS_open:      usize = 2;
const SYS_close:     usize = 3;
const SYS_fstat:     usize = 5;
const SYS_lseek:     usize = 8;
const SYS_dup:       usize = 32;
const SYS_dup2:      usize = 33;
const SYS_getpid:    usize = 39;
const SYS_fork:      usize = 57;
const SYS_execve:    usize = 59;
const SYS_exit:      usize = 60;
const SYS_kill:      usize = 62;
const SYS_ftruncate: usize = 77;
const SYS_brk:       usize = 12;
const SYS_ioctl:     usize = 16;
const SYS_uptime:    usize = 1001;
const SYS_sleep:     usize = 1002;
const SYS_tty_mode:  usize = 1020;

inline fn syscall1(n: usize, a1: usize) usize {
    return asm volatile ("syscall"
        : [ret] "={rax}" (-> usize),
        : [n]  "{rax}" (n),
          [a1] "{rdi}" (a1),
        : .{ .rcx = true, .r11 = true, .memory = true });
}

inline fn syscall3(n: usize, a1: usize, a2: usize, a3: usize) usize {
    return asm volatile ("syscall"
        : [ret] "={rax}" (-> usize),
        : [n]  "{rax}" (n),
          [a1] "{rdi}" (a1),
          [a2] "{rsi}" (a2),
          [a3] "{rdx}" (a3),
        : .{ .rcx = true, .r11 = true, .memory = true });
}

fn sysWrite(fd: usize, ptr: usize, len: usize) void {
    _ = syscall3(SYS_write, fd, ptr, len);
}

fn emit(s: []const u8) void {
    sysWrite(1, @intFromPtr(s.ptr), s.len);
}

fn emitFd(fd: usize, s: []const u8) void {
    sysWrite(fd, @intFromPtr(s.ptr), s.len);
}

fn emitChar(c: u8) void {
    var b = c;
    sysWrite(1, @intFromPtr(&b), 1);
}

// ============================================================================
// ctype.h
// ============================================================================

export fn isdigit(c: c_int) callconv(.c) c_int {
    return @intFromBool(c >= '0' and c <= '9');
}

export fn isxdigit(c: c_int) callconv(.c) c_int {
    return @intFromBool((c >= '0' and c <= '9') or
                        (c >= 'a' and c <= 'f') or
                        (c >= 'A' and c <= 'F'));
}

export fn isalpha(c: c_int) callconv(.c) c_int {
    return @intFromBool((c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z'));
}

export fn isalnum(c: c_int) callconv(.c) c_int {
    return @intFromBool(isdigit(c) != 0 or isalpha(c) != 0);
}

export fn isspace(c: c_int) callconv(.c) c_int {
    return @intFromBool(c == ' ' or c == '\t' or c == '\n' or
                        c == '\r' or c == '\x0C' or c == '\x0B');
}

export fn isupper(c: c_int) callconv(.c) c_int {
    return @intFromBool(c >= 'A' and c <= 'Z');
}

export fn islower(c: c_int) callconv(.c) c_int {
    return @intFromBool(c >= 'a' and c <= 'z');
}

export fn isprint(c: c_int) callconv(.c) c_int {
    return @intFromBool(c >= 0x20 and c <= 0x7E);
}

export fn iscntrl(c: c_int) callconv(.c) c_int {
    return @intFromBool(c < 0x20 or c == 0x7F);
}

export fn ispunct(c: c_int) callconv(.c) c_int {
    return @intFromBool(isprint(c) != 0 and isalnum(c) == 0 and c != ' ');
}

export fn toupper(c: c_int) callconv(.c) c_int {
    if (c >= 'a' and c <= 'z') return c - ('a' - 'A');
    return c;
}

export fn tolower(c: c_int) callconv(.c) c_int {
    if (c >= 'A' and c <= 'Z') return c + ('a' - 'A');
    return c;
}

// ============================================================================
// string.h
// ============================================================================

export fn strlen(s: [*:0]const u8) callconv(.c) usize {
    var i: usize = 0;
    while (s[i] != 0) i += 1;
    return i;
}

export fn strnlen(s: [*:0]const u8, maxlen: usize) callconv(.c) usize {
    var i: usize = 0;
    while (i < maxlen and s[i] != 0) i += 1;
    return i;
}

export fn strcpy(dst: [*:0]u8, src: [*:0]const u8) callconv(.c) [*:0]u8 {
    var i: usize = 0;
    while (src[i] != 0) : (i += 1) dst[i] = src[i];
    dst[i] = 0;
    return dst;
}

export fn strncpy(dst: [*]u8, src: [*]const u8, n: usize) callconv(.c) [*]u8 {
    var i: usize = 0;
    while (i < n and src[i] != 0) : (i += 1) dst[i] = src[i];
    while (i < n) : (i += 1) dst[i] = 0;
    return dst;
}

export fn strcat(dst: [*:0]u8, src: [*:0]const u8) callconv(.c) [*:0]u8 {
    var d = dst + strlen(dst);
    var i: usize = 0;
    while (src[i] != 0) : (i += 1) {
        d[i] = src[i];
    }
    d[i] = 0;
    return dst;
}

export fn strncat(dst: [*:0]u8, src: [*:0]const u8, n: usize) callconv(.c) [*:0]u8 {
    const dlen = strlen(dst);
    var d = dst + dlen;
    var i: usize = 0;
    while (i < n and src[i] != 0) : (i += 1) {
        d[i] = src[i];
    }
    d[i] = 0;
    return dst;
}

export fn strcmp(a: [*:0]const u8, b: [*:0]const u8) callconv(.c) c_int {
    var i: usize = 0;
    while (a[i] != 0 and a[i] == b[i]) i += 1;
    return @as(c_int, a[i]) - @as(c_int, b[i]);
}

export fn strncmp(a: [*:0]const u8, b: [*:0]const u8, n: usize) callconv(.c) c_int {
    var i: usize = 0;
    while (i < n and a[i] != 0 and a[i] == b[i]) i += 1;
    if (i == n) return 0;
    return @as(c_int, a[i]) - @as(c_int, b[i]);
}

export fn strcasecmp(a: [*:0]const u8, b: [*:0]const u8) callconv(.c) c_int {
    var i: usize = 0;
    while (true) {
        const ca: c_int = tolower(a[i]);
        const cb: c_int = tolower(b[i]);
        if (ca != cb or ca == 0) return ca - cb;
        i += 1;
    }
}

export fn strncasecmp(a: [*:0]const u8, b: [*:0]const u8, n: usize) callconv(.c) c_int {
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const ca: c_int = tolower(a[i]);
        const cb: c_int = tolower(b[i]);
        if (ca != cb) return ca - cb;
        if (ca == 0) return 0;
    }
    return 0;
}

export fn strchr(s: [*:0]const u8, c: c_int) callconv(.c) ?[*:0]u8 {
    const ch: u8 = @truncate(@as(c_uint, @bitCast(c)));
    var i: usize = 0;
    while (true) {
        if (s[i] == ch) return @constCast(s + i);
        if (s[i] == 0) return null;
        i += 1;
    }
}

export fn strrchr(s: [*:0]const u8, c: c_int) callconv(.c) ?[*:0]u8 {
    const ch: u8 = @truncate(@as(c_uint, @bitCast(c)));
    var last: ?[*:0]u8 = null;
    var i: usize = 0;
    while (true) {
        if (s[i] == ch) last = @constCast(s + i);
        if (s[i] == 0) break;
        i += 1;
    }
    return last;
}

export fn strstr(haystack: [*:0]const u8, needle: [*:0]const u8) callconv(.c) ?[*:0]u8 {
    const nlen = strlen(needle);
    if (nlen == 0) return @constCast(haystack);
    var i: usize = 0;
    while (haystack[i] != 0) : (i += 1) {
        if (strncmp(haystack + i, needle, nlen) == 0)
            return @constCast(haystack + i);
    }
    return null;
}

export fn strdup(s: [*:0]const u8) callconv(.c) ?[*:0]u8 {
    const n = strlen(s) + 1;
    const p = malloc(n) orelse return null;
    _ = memcpy(@ptrCast(p), s, n);
    return @ptrCast(p);
}

export fn strtok(str: ?[*:0]u8, delim: [*:0]const u8) callconv(.c) ?[*:0]u8 {
    const State = struct { var saved: ?[*:0]u8 = null; };
    var s: [*:0]u8 = if (str) |p| p else (State.saved orelse return null);

    // skip leading delimiters
    while (s[0] != 0 and strchr(delim, s[0]) != null) s += 1;
    if (s[0] == 0) { State.saved = null; return null; }

    const tok = s;
    while (s[0] != 0 and strchr(delim, s[0]) == null) s += 1;
    if (s[0] != 0) {
        s[0] = 0;
        State.saved = s + 1;
    } else {
        State.saved = null;
    }
    return tok;
}

export fn memcpy(noalias d: [*]u8, noalias s: [*]const u8, n: usize) callconv(.c) [*]u8 {
    var i: usize = 0;
    while (i < n) : (i += 1) d[i] = s[i];
    return d;
}

export fn memmove(d: [*]u8, s: [*]const u8, n: usize) callconv(.c) [*]u8 {
    if (@intFromPtr(d) < @intFromPtr(s) or @intFromPtr(d) >= @intFromPtr(s) + n) {
        var i: usize = 0;
        while (i < n) : (i += 1) d[i] = s[i];
    } else {
        var i = n;
        while (i > 0) {
            i -= 1;
            d[i] = s[i];
        }
    }
    return d;
}

export fn memset(d: [*]u8, c: c_int, n: usize) callconv(.c) [*]u8 {
    const b: u8 = @truncate(@as(c_uint, @bitCast(c)));
    var i: usize = 0;
    while (i < n) : (i += 1) d[i] = b;
    return d;
}

export fn memcmp(a: [*]const u8, b: [*]const u8, n: usize) callconv(.c) c_int {
    var i: usize = 0;
    while (i < n) : (i += 1) {
        if (a[i] != b[i]) return @as(c_int, a[i]) - @as(c_int, b[i]);
    }
    return 0;
}

export fn memchr(s: [*]const u8, c: c_int, n: usize) callconv(.c) ?*anyopaque {
    const ch: u8 = @truncate(@as(c_uint, @bitCast(c)));
    var i: usize = 0;
    while (i < n) : (i += 1) {
        if (s[i] == ch) return @constCast(@ptrCast(s + i));
    }
    return null;
}

// ============================================================================
// stdlib.h  (brk-backed bump allocator + numeric conversions)
// ============================================================================

var heap_cur: usize = 0;
var heap_end: usize = 0;

export fn malloc(n: usize) callconv(.c) ?*anyopaque {
    if (heap_cur == 0) {
        heap_cur = syscall1(SYS_brk, 0);
        heap_end = heap_cur;
    }
    const aligned = (heap_cur + 15) & ~@as(usize, 15);
    const end = aligned + n;
    if (end > heap_end) {
        const want = (end + 0xFFF) & ~@as(usize, 0xFFF);
        const got = syscall1(SYS_brk, want);
        if (got < end) return null;
        heap_end = got;
    }
    heap_cur = end;
    return @ptrFromInt(aligned);
}

export fn calloc(nmemb: usize, size: usize) callconv(.c) ?*anyopaque {
    const total = nmemb *% size;
    const p = malloc(total) orelse return null;
    _ = memset(@ptrCast(p), 0, total);
    return p;
}

export fn realloc(ptr: ?*anyopaque, new_size: usize) callconv(.c) ?*anyopaque {
    // Bump allocator — we can't reclaim, so just alloc + copy.
    // The old block is leaked (same as free()).
    const np = malloc(new_size) orelse return null;
    if (ptr) |old| {
        // We don't know the old size, so copy new_size bytes (safe if growing).
        _ = memcpy(@ptrCast(np), @ptrCast(old), new_size);
    }
    return np;
}

export fn free(p: ?*anyopaque) callconv(.c) void {
    _ = p; // bump allocator: no reclamation
}

export fn exit(code: c_int) callconv(.c) noreturn {
    _ = syscall1(SYS_exit, @intCast(@as(i64, code) & 0xFF));
    unreachable;
}

export fn abort() callconv(.c) noreturn {
    exit(134);
}

export fn abs(x: c_int) callconv(.c) c_int {
    return if (x < 0) -x else x;
}

export fn labs(x: c_long) callconv(.c) c_long {
    return if (x < 0) -x else x;
}

/// atoi — parse decimal integer, skip leading whitespace, optional sign.
export fn atoi(s: [*:0]const u8) callconv(.c) c_int {
    return @intCast(atol(s));
}

export fn atol(s: [*:0]const u8) callconv(.c) c_long {
    var i: usize = 0;
    while (isspace(s[i]) != 0) i += 1;
    var neg = false;
    if (s[i] == '-') { neg = true; i += 1; }
    else if (s[i] == '+') { i += 1; }
    var v: c_long = 0;
    while (isdigit(s[i]) != 0) : (i += 1) {
        v = v * 10 + @as(c_long, s[i] - '0');
    }
    return if (neg) -v else v;
}

export fn strtol(s: [*:0]const u8, endptr: ?*?[*:0]u8, base: c_int) callconv(.c) c_long {
    var i: usize = 0;
    while (isspace(s[i]) != 0) i += 1;
    var neg = false;
    if (s[i] == '-') { neg = true; i += 1; }
    else if (s[i] == '+') { i += 1; }
    var radix: c_long = base;
    if (radix == 0) {
        if (s[i] == '0') {
            if (s[i + 1] == 'x' or s[i + 1] == 'X') { radix = 16; i += 2; }
            else { radix = 8; i += 1; }
        } else { radix = 10; }
    } else if (radix == 16 and s[i] == '0' and (s[i + 1] == 'x' or s[i + 1] == 'X')) {
        i += 2;
    }
    var v: c_long = 0;
    while (true) {
        const ch = s[i];
        const digit: c_long = if (ch >= '0' and ch <= '9')
            ch - '0'
        else if (ch >= 'a' and ch <= 'z')
            ch - 'a' + 10
        else if (ch >= 'A' and ch <= 'Z')
            ch - 'A' + 10
        else
            break;
        if (digit >= radix) break;
        v = v * radix + digit;
        i += 1;
    }
    if (endptr) |ep| ep.* = @constCast(s + i);
    return if (neg) -v else v;
}

export fn strtoul(s: [*:0]const u8, endptr: ?*?[*:0]u8, base: c_int) callconv(.c) c_ulong {
    return @bitCast(strtol(s, endptr, base));
}

export fn strtoll(s: [*:0]const u8, endptr: ?*?[*:0]u8, base: c_int) callconv(.c) c_longlong {
    return @intCast(strtol(s, endptr, base));
}


// ============================================================================
// stdio.h
// ============================================================================

export fn putchar(c: c_int) callconv(.c) c_int {
    emitChar(@truncate(@as(c_uint, @bitCast(c))));
    return c;
}

export fn puts(s: [*:0]const u8) callconv(.c) c_int {
    emit(s[0..strlen(s)]);
    emitChar('\n');
    return 0;
}

export fn fputs(s: [*:0]const u8, stream: ?*anyopaque) callconv(.c) c_int {
    // stream == NULL → stdout; 2-pointer trick: stderr is any non-null ptr
    // We map by fd index embedded in the pointer value (1=stdout, 2=stderr).
    const fd: usize = if (stream == null) 1 else @intFromPtr(stream);
    const slice = s[0..strlen(s)];
    emitFd(if (fd == 2) 2 else 1, slice);
    return 0;
}

export fn fputc(c: c_int, stream: ?*anyopaque) callconv(.c) c_int {
    const fd: usize = if (stream == null) 1 else @intFromPtr(stream);
    var b: u8 = @truncate(@as(c_uint, @bitCast(c)));
    sysWrite(if (fd == 2) 2 else 1, @intFromPtr(&b), 1);
    return c;
}

export fn getchar() callconv(.c) c_int {
    var b: u8 = 0;
    const n = syscall3(SYS_read, 0, @intFromPtr(&b), 1);
    if (n == 0) return -1; // EOF
    return b;
}

export fn fflush(stream: ?*anyopaque) callconv(.c) c_int {
    _ = stream;
    return 0; // unbuffered — nothing to flush
}

// ---------------------------------------------------------------------------
// Core formatter: formats into a caller-supplied buffer.
// Returns number of bytes written (not counting the NUL terminator).
// If buf == null or size == 0, just counts the output length (for snprintf).
// ---------------------------------------------------------------------------
fn vformat(buf: ?[*]u8, size: usize, fmt: [*:0]const u8, ap: anytype) usize {
    var out: usize = 0; // bytes written (excl. NUL)

    const putc = struct {
        fn f(b: ?[*]u8, sz: usize, pos: *usize, c: u8) void {
            if (b) |p| {
                if (pos.* + 1 < sz) p[pos.*] = c;
            }
            pos.* += 1;
        }
    }.f;

    const puts_slice = struct {
        fn f(b: ?[*]u8, sz: usize, pos: *usize, s: []const u8) void {
            for (s) |c| {
                if (b) |p| {
                    if (pos.* + 1 < sz) p[pos.*] = c;
                }
                pos.* += 1;
            }
        }
    }.f;

    var i: usize = 0;
    while (fmt[i] != 0) : (i += 1) {
        if (fmt[i] != '%') {
            putc(buf, size, &out, fmt[i]);
            continue;
        }
        i += 1;

        // Flags
        var flag_zero  = false;
        var flag_left  = false;
        var flag_plus  = false;
        var flag_space = false;
        var flag_hash  = false;
        flags: while (true) {
            switch (fmt[i]) {
                '0' => { flag_zero  = true; i += 1; },
                '-' => { flag_left  = true; i += 1; },
                '+' => { flag_plus  = true; i += 1; },
                ' ' => { flag_space = true; i += 1; },
                '#' => { flag_hash  = true; i += 1; },
                else => break :flags,
            }
        }

        // Width
        var width: usize = 0;
        if (fmt[i] == '*') {
            const w = @cVaArg(ap, c_int);
            if (w < 0) { flag_left = true; width = @intCast(-w); }
            else width = @intCast(w);
            i += 1;
        } else {
            while (fmt[i] >= '0' and fmt[i] <= '9') : (i += 1) {
                width = width * 10 + (fmt[i] - '0');
            }
        }

        // Precision
        var prec: usize = 0;
        var has_prec = false;
        if (fmt[i] == '.') {
            has_prec = true;
            i += 1;
            if (fmt[i] == '*') {
                const p = @cVaArg(ap, c_int);
                if (p >= 0) prec = @intCast(p);
                i += 1;
            } else {
                while (fmt[i] >= '0' and fmt[i] <= '9') : (i += 1) {
                    prec = prec * 10 + (fmt[i] - '0');
                }
            }
        }

        // Length modifier
        var is_long      = false;
        var is_long_long = false;
        var is_short     = false;
        if (fmt[i] == 'l') {
            i += 1;
            if (fmt[i] == 'l') { is_long_long = true; i += 1; }
            else is_long = true;
        } else if (fmt[i] == 'h') {
            i += 1;
            is_short = true;
            if (fmt[i] == 'h') i += 1; // hh treated same as h
        } else if (fmt[i] == 'z' or fmt[i] == 't') {
            is_long = true; i += 1;
        }

        const spec = fmt[i];

        // ---- %% ----
        if (spec == '%') { putc(buf, size, &out, '%'); continue; }
        if (spec == 0) break;

        // ---- %c ----
        if (spec == 'c') {
            const ch: u8 = @truncate(@as(c_uint, @bitCast(@cVaArg(ap, c_int))));
            if (!flag_left and width > 1) {
                var w = width - 1;
                while (w > 0) : (w -= 1) putc(buf, size, &out, ' ');
            }
            putc(buf, size, &out, ch);
            if (flag_left and width > 1) {
                var w = width - 1;
                while (w > 0) : (w -= 1) putc(buf, size, &out, ' ');
            }
            continue;
        }

        // ---- %s ----
        if (spec == 's') {
            const raw = @cVaArg(ap, [*:0]const u8);
            const raw_len = strlen(raw);
            const slen = if (has_prec and prec < raw_len) prec else raw_len;
            const pad = if (width > slen) width - slen else 0;
            if (!flag_left) {
                var p = pad;
                while (p > 0) : (p -= 1) putc(buf, size, &out, ' ');
            }
            puts_slice(buf, size, &out, raw[0..slen]);
            if (flag_left) {
                var p = pad;
                while (p > 0) : (p -= 1) putc(buf, size, &out, ' ');
            }
            continue;
        }

        // ---- numeric ----
        const is_signed = spec == 'd' or spec == 'i';
        const is_unsigned = spec == 'u' or spec == 'o' or spec == 'x' or spec == 'X' or spec == 'b';
        const is_ptr = spec == 'p';

        if (is_signed or is_unsigned or is_ptr) {
            // Collect value as u64 (or i64 for signed).
            var uval: u64 = 0;
            var ival: i64 = 0;
            if (is_signed) {
                ival = if (is_long_long) @cVaArg(ap, c_longlong)
                       else if (is_long)     @as(i64, @cVaArg(ap, c_long))
                       else if (is_short)    @as(i64, @as(c_short, @truncate(@cVaArg(ap, c_int))))
                       else                  @as(i64, @cVaArg(ap, c_int));
                uval = @bitCast(ival);
            } else if (is_ptr) {
                uval = @intFromPtr(@cVaArg(ap, ?*anyopaque));
            } else {
                uval = if (is_long_long) @as(u64, @cVaArg(ap, c_ulonglong))
                       else if (is_long)     @as(u64, @cVaArg(ap, c_ulong))
                       else if (is_short)    @as(u64, @as(c_ushort, @truncate(@cVaArg(ap, c_uint))))
                       else                  @as(u64, @cVaArg(ap, c_uint));
            }

            // Determine radix and digit set.
            const radix: u64 = switch (spec) {
                'o'       => 8,
                'x', 'X', 'p' => 16,
                'b'       => 2,
                else      => 10,
            };
            const digits: []const u8 = if (spec == 'X') "0123456789ABCDEF"
                                        else             "0123456789abcdef";

            // Format number into a local buffer.
            var nbuf: [66]u8 = undefined;
            var ni: usize = nbuf.len;

            const negative = is_signed and ival < 0;
            var v: u64 = if (negative) @bitCast(-ival) else uval;

            if (v == 0) {
                if (!has_prec or prec > 0) {
                    ni -= 1;
                    nbuf[ni] = '0';
                }
            } else {
                while (v > 0) : (v /= radix) {
                    ni -= 1;
                    nbuf[ni] = digits[@intCast(v % radix)];
                }
            }

            const num_len = nbuf.len - ni;
            // Precision zero-pad.
            const npad: usize = if (has_prec and prec > num_len) prec - num_len else 0;

            // Prefix (sign / 0x / 0).
            var prefix: []const u8 = "";
            if (negative) prefix = "-"
            else if (flag_plus) prefix = "+"
            else if (flag_space) prefix = " ";
            if (flag_hash) {
                if ((spec == 'x' or spec == 'p') and (v != 0 or num_len > 0)) prefix = "0x"
                else if (spec == 'X') prefix = "0X"
                else if (spec == 'o' and (num_len == 0 or nbuf[ni] != '0')) prefix = "0";
            }
            if (is_ptr) prefix = "0x";

            const total = prefix.len + npad + num_len;
            const pad = if (width > total) width - total else 0;

            if (!flag_left) {
                if (flag_zero) {
                    // pad goes after prefix, before digits
                    puts_slice(buf, size, &out, prefix);
                    var p = npad + pad;
                    while (p > 0) : (p -= 1) putc(buf, size, &out, '0');
                } else {
                    var p = pad;
                    while (p > 0) : (p -= 1) putc(buf, size, &out, ' ');
                    puts_slice(buf, size, &out, prefix);
                    var q = npad;
                    while (q > 0) : (q -= 1) putc(buf, size, &out, '0');
                }
            } else {
                puts_slice(buf, size, &out, prefix);
                var q = npad;
                while (q > 0) : (q -= 1) putc(buf, size, &out, '0');
            }
            puts_slice(buf, size, &out, nbuf[ni..]);
            if (flag_left) {
                var p = pad;
                while (p > 0) : (p -= 1) putc(buf, size, &out, ' ');
            }
            continue;
        }



        // Unknown specifier — echo literally.
        putc(buf, size, &out, '%');
        putc(buf, size, &out, spec);
    }

    // NUL-terminate if we have a buffer.
    if (buf) |p| {
        if (size > 0) p[if (out < size) out else size - 1] = 0;
    }
    return out;
}

export fn printf(fmt: [*:0]const u8, ...) callconv(.c) c_int {
    var ap = @cVaStart();
    defer @cVaEnd(&ap);
    var tmp: [512]u8 = undefined;
    const n = vformat(&tmp, tmp.len, fmt, &ap);
    const actual = if (n < tmp.len) n else tmp.len - 1;
    emit(tmp[0..actual]);
    return @intCast(actual);
}

export fn fprintf(stream: ?*anyopaque, fmt: [*:0]const u8, ...) callconv(.c) c_int {
    var ap = @cVaStart();
    defer @cVaEnd(&ap);
    var tmp: [512]u8 = undefined;
    const n = vformat(&tmp, tmp.len, fmt, &ap);
    const actual = if (n < tmp.len) n else tmp.len - 1;
    const fd: usize = if (stream != null and @intFromPtr(stream) == 2) 2 else 1;
    emitFd(fd, tmp[0..actual]);
    return @intCast(actual);
}

export fn sprintf(buf: [*]u8, fmt: [*:0]const u8, ...) callconv(.c) c_int {
    var ap = @cVaStart();
    defer @cVaEnd(&ap);
    const n = vformat(buf, 0x7FFF_FFFF, fmt, &ap);
    return @intCast(n);
}

export fn snprintf(buf: [*]u8, size: usize, fmt: [*:0]const u8, ...) callconv(.c) c_int {
    var ap = @cVaStart();
    defer @cVaEnd(&ap);
    const n = vformat(buf, size, fmt, &ap);
    return @intCast(n);
}

// vprintf / vsprintf / vsnprintf: C va_list is not directly castable from *anyopaque
// in Zig's type system.  Callers should use printf/sprintf/snprintf instead.
export fn vprintf(fmt: [*:0]const u8, ap: *anyopaque) callconv(.c) c_int {
    _ = ap;
    return printf(fmt);
}

export fn vsprintf(buf: [*]u8, fmt: [*:0]const u8, ap: *anyopaque) callconv(.c) c_int {
    _ = ap;
    return sprintf(buf, fmt);
}

export fn vsnprintf(buf: [*]u8, size: usize, fmt: [*:0]const u8, ap: *anyopaque) callconv(.c) c_int {
    _ = ap;
    return snprintf(buf, size, fmt);
}

// Simple sscanf — supports %d %i %u %s %c %x %o %n %% with optional width.
export fn sscanf(str: [*:0]const u8, fmt: [*:0]const u8, ...) callconv(.c) c_int {
    var ap = @cVaStart();
    defer @cVaEnd(&ap);

    var si: usize = 0; // position in str
    var fi: usize = 0; // position in fmt
    var matched: c_int = 0;

    while (fmt[fi] != 0) : (fi += 1) {
        if (isspace(fmt[fi]) != 0) {
            while (isspace(str[si]) != 0) si += 1;
            continue;
        }
        if (fmt[fi] != '%') {
            if (str[si] != fmt[fi]) break;
            si += 1;
            continue;
        }
        fi += 1;
        // Width
        var width: usize = 0;
        while (fmt[fi] >= '0' and fmt[fi] <= '9') : (fi += 1) {
            width = width * 10 + (fmt[fi] - '0');
        }
        const spec = fmt[fi];
        if (spec == '%') {
            if (str[si] != '%') break;
            si += 1;
            continue;
        }
        if (spec == 'n') {
            const p = @cVaArg(&ap, *c_int);
            p.* = @intCast(si);
            continue;
        }
        // Skip whitespace for numeric.
        if (spec == 'd' or spec == 'i' or spec == 'u' or spec == 'x' or spec == 'o') {
            while (isspace(str[si]) != 0) si += 1;
        }
        if (str[si] == 0) break;
        switch (spec) {
            'd', 'i', 'u' => {
                var neg = false;
                if (str[si] == '-') { neg = true; si += 1; }
                else if (str[si] == '+') si += 1;
                var v: c_long = 0;
                var cnt: usize = 0;
                while ((width == 0 or cnt < width) and isdigit(str[si]) != 0) {
                    v = v * 10 + @as(c_long, str[si] - '0');
                    si += 1;
                    cnt += 1;
                }
                if (cnt == 0) break;
                const p = @cVaArg(&ap, *c_int);
                p.* = @intCast(if (neg) -v else v);
                matched += 1;
            },
            'x', 'X' => {
                var v: c_ulong = 0;
                var cnt: usize = 0;
                while ((width == 0 or cnt < width) and isxdigit(str[si]) != 0) {
                    const ch = str[si];
                    const d: c_ulong = if (ch >= '0' and ch <= '9') ch - '0'
                                       else if (ch >= 'a' and ch <= 'f') ch - 'a' + 10
                                       else ch - 'A' + 10;
                    v = v * 16 + d;
                    si += 1;
                    cnt += 1;
                }
                if (cnt == 0) break;
                const p = @cVaArg(&ap, *c_uint);
                p.* = @intCast(v);
                matched += 1;
            },
            'o' => {
                var v: c_ulong = 0;
                var cnt: usize = 0;
                while ((width == 0 or cnt < width) and str[si] >= '0' and str[si] <= '7') {
                    v = v * 8 + @as(c_ulong, str[si] - '0');
                    si += 1;
                    cnt += 1;
                }
                if (cnt == 0) break;
                const p = @cVaArg(&ap, *c_uint);
                p.* = @intCast(v);
                matched += 1;
            },
            's' => {
                var cnt: usize = 0;
                const p = @cVaArg(&ap, [*]u8);
                while ((width == 0 or cnt < width) and str[si] != 0 and isspace(str[si]) == 0) {
                    p[cnt] = str[si];
                    si += 1;
                    cnt += 1;
                }
                if (cnt == 0) break;
                p[cnt] = 0;
                matched += 1;
            },
            'c' => {
                const p = @cVaArg(&ap, [*]u8);
                const cnt = if (width == 0) @as(usize, 1) else width;
                var j: usize = 0;
                while (j < cnt and str[si] != 0) : ({ j += 1; si += 1; }) {
                    p[j] = str[si];
                }
                matched += 1;
            },
            else => break,
        }
    }
    return matched;
}

export fn scanf(fmt: [*:0]const u8, ...) callconv(.c) c_int {
    // Read one line from stdin, then sscanf it.
    var linebuf: [256]u8 = undefined;
    var n: usize = 0;
    while (n < linebuf.len - 1) {
        var b: u8 = 0;
        const r = syscall3(SYS_read, 0, @intFromPtr(&b), 1);
        if (r == 0 or b == '\n') break;
        linebuf[n] = b;
        n += 1;
    }
    linebuf[n] = 0;

    var ap = @cVaStart();
    defer @cVaEnd(&ap);
    return sscanf(@as([*:0]const u8, @ptrCast(&linebuf)), fmt, &ap);
}

// ============================================================================
// errno.h
// ============================================================================

export var errno: c_int = 0;

const errno_strings = [40][*:0]const u8{
    "Success",
    "Operation not permitted",
    "No such file or directory",
    "No such process",
    "Interrupted system call",
    "I/O error",
    "No such device or address",
    "Argument list too long",
    "Exec format error",
    "Bad file descriptor",
    "No child processes",
    "Try again",
    "Out of memory",
    "Permission denied",
    "Bad address",
    "Unknown error",
    "Device or resource busy",
    "File exists",
    "Cross-device link",
    "No such device",
    "Not a directory",
    "Is a directory",
    "Invalid argument",
    "File table overflow",
    "Too many open files",
    "Not a typewriter",
    "Unknown error",
    "File too large",
    "No space left on device",
    "Illegal seek",
    "Read-only file system",
    "Unknown error",
    "Broken pipe",
    "Unknown error",
    "Math result not representable",
    "Unknown error",
    "File name too long",
    "Unknown error",
    "Function not implemented",
    "Directory not empty",
};

export fn strerror(errnum: c_int) callconv(.c) [*:0]const u8 {
    const i: usize = if (errnum < 0) @intCast(-errnum) else @intCast(errnum);
    if (i < errno_strings.len) return errno_strings[i];
    return "Unknown error";
}

export fn perror(msg: ?[*:0]const u8) callconv(.c) void {
    if (msg) |m| {
        const mlen = strlen(m);
        _ = syscall3(SYS_write, 2, @intFromPtr(m), mlen);
        _ = syscall3(SYS_write, 2, @intFromPtr(@as([*:0]const u8, ": ")), 2);
    }
    const s = strerror(errno);
    _ = syscall3(SYS_write, 2, @intFromPtr(s), strlen(s));
    _ = syscall3(SYS_write, 2, @intFromPtr(@as([*:0]const u8, "\n")), 1);
}

// ============================================================================
// time.h
// ============================================================================

const TmC = extern struct {
    tm_sec: c_int, tm_min: c_int, tm_hour: c_int,
    tm_mday: c_int, tm_mon: c_int, tm_year: c_int,
    tm_wday: c_int, tm_yday: c_int, tm_isdst: c_int,
};
var g_tm: TmC = std.mem.zeroes(TmC);
const std = @import("std");

fn secsToTm(secs: usize, out: *TmC) void {
    var s: usize = secs;
    out.tm_sec  = @intCast(s % 60); s /= 60;
    out.tm_min  = @intCast(s % 60); s /= 60;
    out.tm_hour = @intCast(s % 24); s /= 24;
    var days: usize = s;
    out.tm_wday = @intCast((days + 4) % 7);
    var year: u32 = 1970;
    while (true) {
        const leap: usize = if ((year % 4 == 0 and year % 100 != 0) or year % 400 == 0) 1 else 0;
        if (days < 365 + leap) break;
        days -= 365 + leap;
        year += 1;
    }
    out.tm_year = @intCast(year - 1900);
    out.tm_yday = @intCast(days);
    const leap: usize = if ((year % 4 == 0 and year % 100 != 0) or year % 400 == 0) 1 else 0;
    const mdays = [12]usize{ 31, 28 + leap, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
    var mon: usize = 0;
    while (mon < 12) : (mon += 1) {
        if (days < mdays[mon]) break;
        days -= mdays[mon];
    }
    out.tm_mon  = @intCast(mon);
    out.tm_mday = @intCast(days + 1);
    out.tm_isdst = 0;
}

export fn time(tloc: ?*c_long) callconv(.c) c_long {
    const ticks = syscall1(SYS_uptime, 0);
    const secs: c_long = @intCast(ticks / 100);
    if (tloc) |p| p.* = secs;
    return secs;
}

export fn clock() callconv(.c) c_long {
    return @intCast(syscall1(SYS_uptime, 0));
}

export fn gmtime(timer: *const c_long) callconv(.c) *TmC {
    const s: usize = if (timer.* < 0) 0 else @intCast(timer.*);
    secsToTm(s, &g_tm);
    return &g_tm;
}

export fn localtime(timer: *const c_long) callconv(.c) *TmC {
    return gmtime(timer);
}

export fn mktime(tm: *TmC) callconv(.c) c_long {
    const y: usize = @intCast(tm.tm_year + 1900);
    var days: usize = (y - 1970) * 365 + (y - 1969) / 4;
    const moff = [12]usize{ 0,31,59,90,120,151,181,212,243,273,304,334 };
    days += moff[@intCast(tm.tm_mon)];
    if (tm.tm_mon >= 2 and (y % 4 == 0 and (y % 100 != 0 or y % 400 == 0))) days += 1;
    days += @intCast(tm.tm_mday - 1);
    return @intCast(days * 86400 +
        @as(usize, @intCast(tm.tm_hour)) * 3600 +
        @as(usize, @intCast(tm.tm_min))  * 60  +
        @as(usize, @intCast(tm.tm_sec)));
}

fn w2(buf: [*]u8, off: usize, n: c_int) void {
    buf[off]   = '0' + @as(u8, @intCast(@rem(@divTrunc(n, 10), 10)));
    buf[off+1] = '0' + @as(u8, @intCast(@rem(n, 10)));
}
fn w4(buf: [*]u8, off: usize, n: c_int) void {
    buf[off]   = '0' + @as(u8, @intCast(@rem(@divTrunc(n, 1000), 10)));
    buf[off+1] = '0' + @as(u8, @intCast(@rem(@divTrunc(n, 100), 10)));
    buf[off+2] = '0' + @as(u8, @intCast(@rem(@divTrunc(n, 10), 10)));
    buf[off+3] = '0' + @as(u8, @intCast(@rem(n, 10)));
}

export fn strftime(buf: [*]u8, maxsz: usize, fmt: [*:0]const u8, tm: *const TmC) callconv(.c) usize {
    var out: usize = 0;
    var i: usize = 0;
    while (fmt[i] != 0 and out + 1 < maxsz) : (i += 1) {
        if (fmt[i] != '%') { buf[out] = fmt[i]; out += 1; continue; }
        i += 1;
        switch (fmt[i]) {
            'Y' => { if (out + 4 < maxsz) { w4(buf, out, tm.tm_year + 1900); out += 4; } },
            'y' => { if (out + 2 < maxsz) { w2(buf, out, @rem(tm.tm_year, 100)); out += 2; } },
            'm' => { if (out + 2 < maxsz) { w2(buf, out, tm.tm_mon + 1); out += 2; } },
            'd' => { if (out + 2 < maxsz) { w2(buf, out, tm.tm_mday); out += 2; } },
            'H' => { if (out + 2 < maxsz) { w2(buf, out, tm.tm_hour); out += 2; } },
            'M' => { if (out + 2 < maxsz) { w2(buf, out, tm.tm_min);  out += 2; } },
            'S' => { if (out + 2 < maxsz) { w2(buf, out, tm.tm_sec);  out += 2; } },
            'n' => { buf[out] = '\n'; out += 1; },
            't' => { buf[out] = '\t'; out += 1; },
            '%' => { buf[out] = '%';  out += 1; },
            else => {},
        }
    }
    buf[out] = 0;
    return out;
}

// ============================================================================
// signal.h
// ============================================================================

const NSIG: usize = 32;
var sig_handlers: [NSIG]usize = [1]usize{0} ** NSIG;

export fn signal(signum: c_int, handler: usize) callconv(.c) usize {
    if (signum < 0 or signum >= NSIG) return @bitCast(@as(isize, -1));
    const idx: usize = @intCast(signum);
    const old = sig_handlers[idx];
    sig_handlers[idx] = handler;
    return old;
}

export fn kill(pid: c_int, sig: c_int) callconv(.c) c_int {
    const r = @as(isize, @bitCast(asm volatile ("syscall"
        : [ret] "={rax}" (-> usize),
        : [n]   "{rax}" (SYS_kill),
          [a1]  "{rdi}" (@as(usize, @bitCast(@as(isize, pid)))),
          [a2]  "{rsi}" (@as(usize, @bitCast(@as(isize, sig)))),
        : .{ .rcx = true, .r11 = true, .memory = true })));
    if (r < 0) { errno = @intCast(-r); return -1; }
    return 0;
}

export fn raise(sig: c_int) callconv(.c) c_int {
    return kill(@intCast(syscall1(SYS_getpid, 0)), sig);
}

// ============================================================================
// setjmp.h  jmp_buf = [rbx, rbp, r12, r13, r14, r15, rsp, rip]
// ============================================================================

export fn setjmp(env: [*]usize) callconv(.c) c_int {
    asm volatile (
        \\movq %%rbx,    0(%[e])
        \\movq %%rbp,    8(%[e])
        \\movq %%r12,   16(%[e])
        \\movq %%r13,   24(%[e])
        \\movq %%r14,   32(%[e])
        \\movq %%r15,   40(%[e])
        \\movq %%rsp,   48(%[e])
        \\movq (%%rsp), %%rax
        \\movq %%rax,   56(%[e])
        :
        : [e] "r" (env),
        : .{ .rax = true, .memory = true }
    );
    return 0;
}

export fn longjmp(env: [*]usize, val: c_int) callconv(.c) noreturn {
    const v: usize = if (val == 0) 1 else @intCast(val);
    asm volatile (
        \\movq  0(%[e]), %%rbx
        \\movq  8(%[e]), %%rbp
        \\movq 16(%[e]), %%r12
        \\movq 24(%[e]), %%r13
        \\movq 32(%[e]), %%r14
        \\movq 40(%[e]), %%r15
        \\movq 48(%[e]), %%rsp
        \\movq 56(%[e]), %%rcx
        \\movq %[v],     %%rax
        \\jmpq *%%rcx
        :
        : [e] "r" (env),
          [v] "r" (v),
        : .{ .rbx=true, .rbp=true, .r12=true, .r13=true,
             .r14=true, .r15=true, .rsp=true, .rcx=true,
             .rax=true, .memory=true }
    );
    unreachable;
}

// ============================================================================
// math.h — integer-only fast path
// ============================================================================

export fn llabs(x: c_longlong) callconv(.c) c_longlong {
    return if (x < 0) -x else x;
}

export fn ipow(base: c_longlong, exp: c_uint) callconv(.c) c_longlong {
    var result: c_longlong = 1;
    var b = base;
    var e = exp;
    while (e > 0) : (e >>= 1) {
        if (e & 1 != 0) result *%= b;
        b *%= b;
    }
    return result;
}

export fn isqrt(n: c_ulong) callconv(.c) c_ulong {
    if (n == 0) return 0;
    var x: c_ulong = n;
    var y: c_ulong = (x + 1) / 2;
    while (y < x) { x = y; y = (x + n / x) / 2; }
    return x;
}

export fn gcd(a: c_ulong, b: c_ulong) callconv(.c) c_ulong {
    var x = a; var y = b;
    while (y != 0) { const t = y; y = x % y; x = t; }
    return x;
}

export fn lcm(a: c_ulong, b: c_ulong) callconv(.c) c_ulong {
    if (a == 0 or b == 0) return 0;
    return a / gcd(a, b) *% b;
}

// ============================================================================
// unistd.h
// ============================================================================

var g_null_env: ?[*:0]u8 = null;

export fn read(fd: c_int, buf: [*]u8, count: usize) callconv(.c) isize {
    const r = @as(isize, @bitCast(syscall3(SYS_read, @intCast(fd), @intFromPtr(buf), count)));
    if (r < 0) { errno = @intCast(-r); return -1; }
    return r;
}

export fn write(fd: c_int, buf: [*]const u8, count: usize) callconv(.c) isize {
    const r = @as(isize, @bitCast(syscall3(SYS_write, @intCast(fd), @intFromPtr(buf), count)));
    if (r < 0) { errno = @intCast(-r); return -1; }
    return r;
}

export fn close(fd: c_int) callconv(.c) c_int {
    const r = @as(isize, @bitCast(syscall1(SYS_close, @intCast(fd))));
    if (r < 0) { errno = @intCast(-r); return -1; }
    return 0;
}

export fn dup(oldfd: c_int) callconv(.c) c_int {
    const r = @as(isize, @bitCast(asm volatile ("syscall"
        : [ret] "={rax}" (-> usize),
        : [n]  "{rax}" (SYS_dup),
          [a1] "{rdi}" (@as(usize, @intCast(oldfd))),
        : .{ .rcx = true, .r11 = true, .memory = true })));
    if (r < 0) { errno = @intCast(-r); return -1; }
    return @intCast(r);
}

export fn dup2(oldfd: c_int, newfd: c_int) callconv(.c) c_int {
    const r = @as(isize, @bitCast(syscall3(SYS_dup2, @intCast(oldfd), @intCast(newfd), 0)));
    if (r < 0) { errno = @intCast(-r); return -1; }
    return @intCast(r);
}

export fn getpid() callconv(.c) c_int {
    return @intCast(syscall1(SYS_getpid, 0));
}

export fn isatty(fd: c_int) callconv(.c) c_int {
    return if (fd >= 0 and fd <= 2) 1 else 0;
}

export fn access(path: [*:0]const u8, mode: c_int) callconv(.c) c_int {
    _ = mode;
    const fd = @as(isize, @bitCast(syscall3(SYS_open, @intFromPtr(path), 0, 0)));
    if (fd < 0) { errno = 2; return -1; }
    _ = syscall1(SYS_close, @intCast(fd));
    return 0;
}

export fn getenv(name: [*:0]const u8) callconv(.c) ?[*:0]u8 {
    _ = name;
    return null;
}

export fn sleep(seconds: c_uint) callconv(.c) c_uint {
    _ = syscall1(SYS_sleep, seconds);
    return 0;
}

export fn fork() callconv(.c) c_int {
    const r = @as(isize, @bitCast(asm volatile ("syscall"
        : [ret] "={rax}" (-> usize),
        : [n] "{rax}" (SYS_fork),
        : .{ .rcx = true, .r11 = true, .memory = true })));
    if (r < 0) { errno = @intCast(-r); return -1; }
    return @intCast(r);
}

export fn execve(path: [*:0]const u8, argv: [*]const ?[*:0]const u8, envp: [*]const ?[*:0]const u8) callconv(.c) c_int {
    _ = envp;
    const r = @as(isize, @bitCast(syscall3(SYS_execve, @intFromPtr(path), @intFromPtr(argv), 0)));
    if (r < 0) { errno = @intCast(-r); }
    return -1;
}

export fn execv(path: [*:0]const u8, argv: [*]const ?[*:0]const u8) callconv(.c) c_int {
    return execve(path, argv, @ptrCast(&g_null_env));
}

export fn _exit(status: c_int) callconv(.c) noreturn {
    _ = syscall1(SYS_exit, @intCast(status));
    unreachable;
}

export fn symlink(_target: [*:0]const u8, _linkpath: [*:0]const u8) callconv(.c) c_int {
    _ = _target; _ = _linkpath;
    errno = 38;
    return -1;
}

export fn readlink(_path: [*:0]const u8, _buf: [*]u8, _bufsiz: usize) callconv(.c) isize {
    _ = _path; _ = _buf; _ = _bufsiz;
    errno = 38;
    return -1;
}

// ============================================================================
// fcntl.h / sys/stat.h / sys/ioctl.h / termios.h / sys/time.h / sys/wait.h
// ============================================================================

const SYS_open_z:      usize = 2;
const SYS_lseek_z:     usize = 8;
const SYS_fstat_z:     usize = 5;
const SYS_ftruncate_z: usize = 77;
const SYS_mkdir_z:     usize = 83;
const SYS_wait4_z:     usize = 61;
const SYS_tty_mode_z:  usize = 1020;

export fn open(path: [*:0]const u8, flags: c_int, ...) callconv(.c) c_int {
    const r = @as(isize, @bitCast(syscall3(SYS_open_z, @intFromPtr(path), @intCast(flags), 0o644)));
    if (r < 0) { errno = @intCast(-r); return -1; }
    return @intCast(r);
}

export fn creat(path: [*:0]const u8, mode: c_int) callconv(.c) c_int {
    _ = mode;
    return open(path, 0o100 | 0o001 | 0o1000); // O_CREAT|O_WRONLY|O_TRUNC
}

export fn lseek(fd: c_int, offset: c_long, whence: c_int) callconv(.c) c_long {
    const r = @as(isize, @bitCast(syscall3(SYS_lseek_z, @intCast(fd), @bitCast(offset), @intCast(whence))));
    if (r < 0) { errno = @intCast(-r); return -1; }
    return @intCast(r);
}

export fn ftruncate(fd: c_int, length: c_long) callconv(.c) c_int {
    const r = @as(isize, @bitCast(syscall3(SYS_ftruncate_z, @intCast(fd), @bitCast(length), 0)));
    if (r < 0) { errno = @intCast(-r); return -1; }
    return 0;
}

// Linux x86_64 stat structure (128 bytes)
const LinuxStat = extern struct {
    st_dev:     u64,
    st_ino:     u64,
    st_nlink:   u64,
    st_mode:    u32,
    st_uid:     u32,
    st_gid:     u32,
    _pad0:      i32,
    st_rdev:    u64,
    st_size:    i64,
    st_blksize: i64,
    st_blocks:  i64,
    st_atime:   i64,
    st_atime_ns:i64,
    st_mtime:   i64,
    st_mtime_ns:i64,
    st_ctime:   i64,
    st_ctime_ns:i64,
    _unused:    [3]i64,
};

// Our C-facing stat struct (matches sys/stat.h)
const CStat = extern struct {
    st_dev:     u64,
    st_ino:     u64,
    st_mode:    u32,
    st_nlink:   u32,
    st_uid:     u32,
    st_gid:     u32,
    st_rdev:    u64,
    st_size:    i64,
    st_blksize: i64,
    st_blocks:  i64,
    st_atime:   i64,
    st_mtime:   i64,
    st_ctime:   i64,
};

export fn fstat(fd: c_int, buf: *CStat) callconv(.c) c_int {
    var ls: LinuxStat = undefined;
    const r = @as(isize, @bitCast(asm volatile ("syscall"
        : [ret] "={rax}" (-> usize),
        : [n]   "{rax}" (SYS_fstat_z),
          [a1]  "{rdi}" (@as(usize, @intCast(fd))),
          [a2]  "{rsi}" (@intFromPtr(&ls)),
        : .{ .rcx = true, .r11 = true, .memory = true })));
    if (r < 0) { errno = @intCast(-r); return -1; }
    buf.st_dev     = ls.st_dev;
    buf.st_ino     = ls.st_ino;
    buf.st_mode    = ls.st_mode;
    buf.st_nlink   = @intCast(ls.st_nlink);
    buf.st_uid     = ls.st_uid;
    buf.st_gid     = ls.st_gid;
    buf.st_rdev    = ls.st_rdev;
    buf.st_size    = ls.st_size;
    buf.st_blksize = ls.st_blksize;
    buf.st_blocks  = ls.st_blocks;
    buf.st_atime   = ls.st_atime;
    buf.st_mtime   = ls.st_mtime;
    buf.st_ctime   = ls.st_ctime;
    return 0;
}

export fn stat(path: [*:0]const u8, buf: *CStat) callconv(.c) c_int {
    // Open + fstat + close
    const fd = open(path, 0); // O_RDONLY
    if (fd < 0) return -1;
    const r = fstat(fd, buf);
    _ = syscall1(3, @intCast(fd)); // close
    return r;
}

export fn mkdir_c(path: [*:0]const u8, mode: c_uint) callconv(.c) c_int {
    const r = @as(isize, @bitCast(syscall3(SYS_mkdir_z, @intFromPtr(path), @intCast(mode), 0)));
    if (r < 0) { errno = @intCast(-r); return -1; }
    return 0;
}

// ioctl: TIOCGWINSZ returns 100x75 (800x600 / 8px font)
export fn ioctl(fd: c_int, request: c_ulong, ...) callconv(.c) c_int {
    _ = fd;
    if (request == 0x5413) { // TIOCGWINSZ
        var ap = @cVaStart();
        defer @cVaEnd(&ap);
        const ws = @cVaArg(&ap, *anyopaque);
        const p: [*]u16 = @ptrCast(@alignCast(ws));
        p[0] = 75;  // ws_row
        p[1] = 100; // ws_col
        p[2] = 0;
        p[3] = 0;
        return 0;
    }
    // All other ioctls fail silently
    return -1;
}

// termios: backed by SYS_tty_mode
// struct termios layout (Linux x86_64):
//   c_iflag(4) c_oflag(4) c_cflag(4) c_lflag(4) c_line(1) c_cc[32](32) ...
// c_lflag is at byte offset 12.
var g_raw_mode: bool = false;
var g_orig_termios: [60]u8 = [1]u8{0} ** 60; // saved termios bytes (opaque)

export fn tcgetattr(fd: c_int, t: *anyopaque) callconv(.c) c_int {
    _ = fd;
    // Return a synthetic termios with ICANON|ECHO set (cooked mode)
    const p: [*]u8 = @ptrCast(t);
    @memset(p[0..60], 0);
    // c_lflag at offset 12: set ICANON(0o002)|ECHO(0o010)|ISIG(0o001)
    const lflag: *u32 = @ptrCast(@alignCast(p + 12));
    lflag.* = 0o000002 | 0o000010 | 0o000001; // ICANON|ECHO|ISIG
    // c_cc[VMIN]=1, c_cc[VTIME]=0 (at c_cc = offset 17, VMIN=6, VTIME=5)
    p[17 + 6] = 1; // VMIN
    p[17 + 5] = 0; // VTIME
    @memcpy(g_orig_termios[0..60], p[0..60]);
    return 0;
}

export fn tcsetattr(fd: c_int, action: c_int, t: *const anyopaque) callconv(.c) c_int {
    _ = fd; _ = action;
    const p: [*]const u8 = @ptrCast(t);
    const lflag: *const u32 = @ptrCast(@alignCast(p + 12));
    // If ICANON is cleared -> raw mode
    const want_raw = (lflag.* & 0o000002) == 0;
    if (want_raw != g_raw_mode) {
        _ = syscall1(SYS_tty_mode_z, if (want_raw) 1 else 0);
        g_raw_mode = want_raw;
    }
    return 0;
}

export fn gettimeofday(tv: ?*anyopaque, tz: ?*anyopaque) callconv(.c) c_int {
    _ = tz;
    if (tv) |p| {
        const t: *[2]c_long = @ptrCast(@alignCast(p));
        const ticks = syscall1(SYS_uptime, 0);
        t[0] = @intCast(ticks / 100);
        t[1] = @intCast((ticks % 100) * 10000);
    }
    return 0;
}

export fn waitpid(pid: c_int, status: ?*c_int, options: c_int) callconv(.c) c_int {
    const r = @as(isize, @bitCast(asm volatile ("syscall"
        : [ret] "={rax}" (-> usize),
        : [n]   "{rax}" (SYS_wait4_z),
          [a1]  "{rdi}" (@as(usize, @bitCast(@as(isize, pid)))),
          [a2]  "{rsi}" (@intFromPtr(if (status) |s| s else @as(?*c_int, null))),
          [a3]  "{rdx}" (@as(usize, @intCast(options))),
        : .{ .rcx = true, .r11 = true, .memory = true })));
    if (r < 0) { errno = @intCast(-r); return -1; }
    return @intCast(r);
}

export fn wait(status: ?*c_int) callconv(.c) c_int {
    return waitpid(-1, status, 0);
}

// ============================================================================
// atexit / FILE* I/O (fopen, fclose, getline, fwrite, fread, feof, ferror)
// ============================================================================

// atexit — simple fixed-size handler table
const ATEXIT_MAX = 32;
var atexit_handlers: [ATEXIT_MAX]?*const fn() callconv(.c) void = [1]?*const fn() callconv(.c) void{null} ** ATEXIT_MAX;
var atexit_count: usize = 0;

export fn atexit(handler: *const fn() callconv(.c) void) callconv(.c) c_int {
    if (atexit_count >= ATEXIT_MAX) return -1;
    atexit_handlers[atexit_count] = handler;
    atexit_count += 1;
    return 0;
}

// FILE* backed by a plain file descriptor.
// We represent FILE* as (fd + 1) cast to *anyopaque so fd=0 → ptr=1 (non-null).
// Negative fd values are used for error state.

fn fdToFILE(fd: c_int) ?*anyopaque {
    if (fd < 0) return null;
    return @ptrFromInt(@as(usize, @intCast(fd)) + 1);
}
fn FILEtoFd(f: *anyopaque) c_int {
    const v: usize = @intFromPtr(f);
    if (v == 0) return -1;
    return @intCast(v - 1);
}

export fn fopen(path: [*:0]const u8, mode: [*:0]const u8) callconv(.c) ?*anyopaque {
    const flags: c_int = if (mode[0] == 'w') 0o100 | 0o001 | 0o1000  // O_CREAT|O_WRONLY|O_TRUNC
                         else if (mode[0] == 'a') 0o100 | 0o001 | 0o2000  // O_CREAT|O_WRONLY|O_APPEND
                         else 0; // O_RDONLY
    const fd = open(path, flags);
    return fdToFILE(fd);
}

export fn fclose(f: ?*anyopaque) callconv(.c) c_int {
    if (f == null) return -1;
    const fd = FILEtoFd(f.?);
    return close(fd);
}

export fn fread(buf: [*]u8, size: usize, nmemb: usize, f: ?*anyopaque) callconv(.c) usize {
    if (f == null) return 0;
    const fd = FILEtoFd(f.?);
    const n = @as(isize, @bitCast(syscall3(SYS_read, @intCast(fd), @intFromPtr(buf), size * nmemb)));
    if (n <= 0) return 0;
    return @intCast(@divTrunc(n, @as(isize, @intCast(size))));
}


export fn fwrite(buf: [*]const u8, size: usize, nmemb: usize, f: ?*anyopaque) callconv(.c) usize {
    if (f == null) return 0;
    const fd = FILEtoFd(f.?);
    // stdout/stderr are fd 1/2 from our stdio stubs
    const actual_fd: usize = if (@intFromPtr(f) == 1) 1
                             else if (@intFromPtr(f) == 2) 2
                             else @intCast(fd);
    const n = @as(isize, @bitCast(syscall3(SYS_write, actual_fd, @intFromPtr(buf), size * nmemb)));
    if (n <= 0) return 0;
    return @intCast(@divTrunc(n, @as(isize, @intCast(size))));
}

export fn feof(f: ?*anyopaque) callconv(.c) c_int {
    _ = f;
    return 0; // simplified: let read return 0 for EOF
}

export fn ferror(f: ?*anyopaque) callconv(.c) c_int {
    _ = f;
    return 0;
}

// getline: read a line from FILE*, growing *lineptr as needed.
// Returns number of bytes read (including '\n'), or -1 on EOF/error.
export fn getline(lineptr: *?[*:0]u8, n: *usize, f: ?*anyopaque) callconv(.c) isize {
    if (f == null) return -1;
    const fd = FILEtoFd(f.?);
    var buf: [1]u8 = undefined;
    var total: usize = 0;
    var capacity = n.*;
    var ptr = lineptr.*;

    while (true) {
        const r = @as(isize, @bitCast(syscall3(SYS_read, @intCast(fd), @intFromPtr(&buf), 1)));
        if (r <= 0) {
            if (total == 0) return -1;
            break;
        }
        // Grow buffer if needed (total + 2: char + null)
        if (ptr == null or total + 2 > capacity) {
            const new_cap = if (capacity < 64) 128 else capacity * 2;
            const new_ptr: ?*anyopaque = realloc(if (ptr) |p| @ptrCast(p) else null, new_cap);
            if (new_ptr == null) return -1;
            ptr = @ptrCast(new_ptr);
            capacity = new_cap;
        }
        ptr.?[total] = buf[0];
        total += 1;
        if (buf[0] == '\n') break;
    }
    if (ptr != null) ptr.?[total] = 0;
    lineptr.* = ptr;
    n.* = capacity;
    return @intCast(total);
}

// ============================================================================
// crt0
// ============================================================================

extern fn main() c_int;

export fn _start() callconv(.c) noreturn {
    const ret = main();
    // Run atexit handlers in reverse order.
    var i = atexit_count;
    while (i > 0) {
        i -= 1;
        if (atexit_handlers[i]) |h| h();
    }
    exit(ret);
}