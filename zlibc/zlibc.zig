//! ZLibc — Nevara's own minimal C standard library, written in Zig.
//!
//! NOT musl-ABI compatible: it exists so Nevara can compile its own C sources
//! against a small, all-Zig libc — not to run prebuilt Linux binaries. It sits
//! directly on the kernel syscall ABI; no external dependencies.

const SYS_write: usize = 1;
const SYS_read: usize = 0;
const SYS_brk: usize = 12;
const SYS_exit: usize = 60;

inline fn syscall1(n: usize, a1: usize) usize {
    return asm volatile ("syscall"
        : [ret] "={rax}" (-> usize),
        : [n] "{rax}" (n),
          [a1] "{rdi}" (a1),
        : .{ .rcx = true, .r11 = true, .memory = true });
}

inline fn syscall3(n: usize, a1: usize, a2: usize, a3: usize) usize {
    return asm volatile ("syscall"
        : [ret] "={rax}" (-> usize),
        : [n] "{rax}" (n),
          [a1] "{rdi}" (a1),
          [a2] "{rsi}" (a2),
          [a3] "{rdx}" (a3),
        : .{ .rcx = true, .r11 = true, .memory = true });
}

fn sysWrite(ptr: usize, len: usize) void {
    _ = syscall3(SYS_write, 1, ptr, len);
}

fn emit(s: []const u8) void {
    sysWrite(@intFromPtr(s.ptr), s.len);
}

fn emitChar(c: u8) void {
    var b = c;
    sysWrite(@intFromPtr(&b), 1);
}

// ---- string.h ---------------------------------------------------------------

export fn strlen(s: [*:0]const u8) callconv(.c) usize {
    var i: usize = 0;
    while (s[i] != 0) i += 1;
    return i;
}

export fn strcpy(dst: [*:0]u8, src: [*:0]const u8) callconv(.c) [*:0]u8 {
    var i: usize = 0;
    while (src[i] != 0) : (i += 1) dst[i] = src[i];
    dst[i] = 0;
    return dst;
}

export fn strcmp(a: [*:0]const u8, b: [*:0]const u8) callconv(.c) c_int {
    var i: usize = 0;
    while (a[i] != 0 and a[i] == b[i]) i += 1;
    return @as(c_int, a[i]) - @as(c_int, b[i]);
}

export fn memcpy(noalias d: [*]u8, noalias s: [*]const u8, n: usize) callconv(.c) [*]u8 {
    var i: usize = 0;
    while (i < n) : (i += 1) d[i] = s[i];
    return d;
}

export fn memset(d: [*]u8, c: c_int, n: usize) callconv(.c) [*]u8 {
    const b: u8 = @truncate(@as(c_uint, @bitCast(c)));
    var i: usize = 0;
    while (i < n) : (i += 1) d[i] = b;
    return d;
}

// ---- stdlib.h (brk-backed bump allocator) -----------------------------------

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

export fn free(p: ?*anyopaque) callconv(.c) void {
    _ = p; // bump allocator: no reclamation
}

export fn exit(code: c_int) callconv(.c) noreturn {
    _ = syscall1(SYS_exit, @intCast(@as(i64, code) & 0xFF));
    unreachable;
}

// ---- stdio.h ----------------------------------------------------------------

export fn putchar(c: c_int) callconv(.c) c_int {
    emitChar(@truncate(@as(c_uint, @bitCast(c))));
    return c;
}

export fn puts(s: [*:0]const u8) callconv(.c) c_int {
    emit(s[0..strlen(s)]);
    emitChar('\n');
    return 0;
}

fn emitSigned(value: i64) void {
    var buf: [21]u8 = undefined;
    var v = value;
    var neg = false;
    if (v < 0) {
        neg = true;
        v = -v;
    }
    var i: usize = buf.len;
    if (v == 0) {
        i -= 1;
        buf[i] = '0';
    }
    while (v > 0) : (v = @divTrunc(v, 10)) {
        i -= 1;
        buf[i] = '0' + @as(u8, @intCast(@mod(v, 10)));
    }
    if (neg) {
        i -= 1;
        buf[i] = '-';
    }
    emit(buf[i..]);
}

fn emitHex(value: u64) void {
    const digits = "0123456789abcdef";
    var buf: [16]u8 = undefined;
    var i: usize = buf.len;
    var v = value;
    if (v == 0) {
        i -= 1;
        buf[i] = '0';
    }
    while (v > 0) : (v >>= 4) {
        i -= 1;
        buf[i] = digits[@intCast(v & 0xF)];
    }
    emit(buf[i..]);
}

export fn printf(fmt: [*:0]const u8, ...) callconv(.c) c_int {
    var ap = @cVaStart();
    defer @cVaEnd(&ap);

    var i: usize = 0;
    while (fmt[i] != 0) : (i += 1) {
        if (fmt[i] != '%') {
            emitChar(fmt[i]);
            continue;
        }
        i += 1;
        switch (fmt[i]) {
            'd', 'i' => emitSigned(@cVaArg(&ap, c_int)),
            'u' => emitSigned(@as(i64, @cVaArg(&ap, c_uint))),
            'x' => emitHex(@cVaArg(&ap, c_uint)),
            'p' => {
                emit("0x");
                emitHex(@intFromPtr(@cVaArg(&ap, ?*anyopaque)));
            },
            's' => emit(spanZ(@cVaArg(&ap, [*:0]const u8))),
            'c' => emitChar(@truncate(@as(c_uint, @bitCast(@cVaArg(&ap, c_int))))),
            '%' => emitChar('%'),
            0 => break,
            else => {
                emitChar('%');
                emitChar(fmt[i]);
            },
        }
    }
    return 0;
}

fn spanZ(s: [*:0]const u8) []const u8 {
    return s[0..strlen(s)];
}

// ---- crt0 -------------------------------------------------------------------

extern fn main() c_int;

export fn _start() callconv(.c) noreturn {
    const ret = main();
    exit(ret);
}
