//! Freestanding C mem builtins.
//!
//! The compiler lowers struct copies, slice fills, etc. into calls to these
//! symbols, and std code (panic/Writer) references them too. When the kernel is
//! linked by an external `ld.lld` (instead of Zig's own driver) compiler_rt is
//! not pulled in, so we must define them ourselves.

export fn memcpy(noalias dest: [*]u8, noalias src: [*]const u8, n: usize) callconv(.c) [*]u8 {
    var i: usize = 0;
    while (i < n) : (i += 1) dest[i] = src[i];
    return dest;
}

export fn memmove(dest: [*]u8, src: [*]const u8, n: usize) callconv(.c) [*]u8 {
    if (@intFromPtr(dest) < @intFromPtr(src)) {
        var i: usize = 0;
        while (i < n) : (i += 1) dest[i] = src[i];
    } else {
        var i: usize = n;
        while (i > 0) {
            i -= 1;
            dest[i] = src[i];
        }
    }
    return dest;
}

export fn memset(dest: [*]u8, value: c_int, n: usize) callconv(.c) [*]u8 {
    const byte: u8 = @truncate(@as(c_uint, @bitCast(value)));
    var i: usize = 0;
    while (i < n) : (i += 1) dest[i] = byte;
    return dest;
}

export fn memcmp(a: [*]const u8, b: [*]const u8, n: usize) callconv(.c) c_int {
    var i: usize = 0;
    while (i < n) : (i += 1) {
        if (a[i] != b[i]) {
            return @as(c_int, a[i]) - @as(c_int, b[i]);
        }
    }
    return 0;
}
