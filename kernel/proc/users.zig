//! Kernel user database — simple table of up to MAX_USERS users.
//! Persisted to /etc/passwd via vfs on every modification.

const std = @import("std");
const vfs = @import("../fs/vfs.zig");

pub const MAX_USERS = 32;

pub const User = struct {
    uid: u32 = 0,
    gid: u32 = 0,
    name: [32]u8 = [_]u8{0} ** 32,
    home: [64]u8 = [_]u8{0} ** 64,
    shell: [32]u8 = [_]u8{0} ** 32,
    used: bool = false,

    pub fn nameslice(self: *const User) []const u8 {
        var l: usize = 0;
        while (l < self.name.len and self.name[l] != 0) l += 1;
        return self.name[0..l];
    }
    pub fn homeslice(self: *const User) []const u8 {
        var l: usize = 0;
        while (l < self.home.len and self.home[l] != 0) l += 1;
        return self.home[0..l];
    }
    pub fn shellslice(self: *const User) []const u8 {
        var l: usize = 0;
        while (l < self.shell.len and self.shell[l] != 0) l += 1;
        return self.shell[0..l];
    }
};

var db: [MAX_USERS]User = blk: {
    var arr = [_]User{.{}} ** MAX_USERS;
    arr[0] = .{
        .uid = 0,
        .gid = 0,
        .used = true,
        .name = [_]u8{ 'r', 'o', 'o', 't' } ++ [_]u8{0} ** 28,
        .home = [_]u8{ '/', 'r', 'o', 'o', 't' } ++ [_]u8{0} ** 59,
        .shell = [_]u8{ '/', 'b', 'i', 'n', '/', 'n', 's', 'h' } ++ [_]u8{0} ** 24,
    };
    break :blk arr;
};
var next_uid: u32 = 1000;

pub fn findByUid(uid: u32) ?*User {
    for (&db) |*u| {
        if (u.used and u.uid == uid) return u;
    }
    return null;
}

pub fn findByName(name: []const u8) ?*User {
    for (&db) |*u| {
        if (u.used and std.mem.eql(u8, u.nameslice(), name)) return u;
    }
    return null;
}

pub fn add(name: []const u8, home: []const u8, shell: []const u8) i32 {
    if (findByName(name) != null) return -17; // EEXIST
    for (&db) |*u| {
        if (!u.used) {
            u.* = .{ .uid = next_uid, .gid = next_uid, .used = true };
            const nl = @min(name.len, u.name.len - 1);
            @memcpy(u.name[0..nl], name[0..nl]);
            const hl = @min(home.len, u.home.len - 1);
            @memcpy(u.home[0..hl], home[0..hl]);
            const sl = @min(shell.len, u.shell.len - 1);
            @memcpy(u.shell[0..sl], shell[0..sl]);
            next_uid += 1;
            persistPasswd();
            return @intCast(u.uid);
        }
    }
    return -12; // ENOMEM
}

pub fn remove(name: []const u8) bool {
    const u = findByName(name) orelse return false;
    if (u.uid == 0) return false; // cannot remove root
    u.* = .{};
    persistPasswd();
    return true;
}

/// Rewrite /etc/passwd from the in-memory DB.
pub fn persistPasswd() void {
    const node = vfs.resolve("/etc/passwd") catch return;
    node.size = 0;
    var off: usize = 0;
    for (&db) |*u| {
        if (!u.used) continue;
        // Format: name:x:uid:gid::home:shell\n
        var line: [256]u8 = undefined;
        var llen: usize = 0;
        const ns = u.nameslice();
        @memcpy(line[llen .. llen + ns.len], ns);
        llen += ns.len;
        @memcpy(line[llen .. llen + 3], ":x:");
        llen += 3;
        llen += fmtDec(u.uid, line[llen..]);
        line[llen] = ':';
        llen += 1;
        llen += fmtDec(u.gid, line[llen..]);
        @memcpy(line[llen .. llen + 2], "::");
        llen += 2;
        const hs = u.homeslice();
        @memcpy(line[llen .. llen + hs.len], hs);
        llen += hs.len;
        line[llen] = ':';
        llen += 1;
        const ss = u.shellslice();
        @memcpy(line[llen .. llen + ss.len], ss);
        llen += ss.len;
        line[llen] = '\n';
        llen += 1;
        _ = vfs.writeAt(node, line[0..llen], off) catch {};
        off += llen;
    }
}

/// Write decimal representation of v into buf. Returns bytes written.
fn fmtDec(v: u32, buf: []u8) usize {
    if (v == 0) {
        buf[0] = '0';
        return 1;
    }
    var tmp: [10]u8 = undefined;
    var i: usize = tmp.len;
    var n = v;
    while (n > 0) : (n /= 10) {
        i -= 1;
        tmp[i] = '0' + @as(u8, @intCast(n % 10));
    }
    const len = tmp.len - i;
    @memcpy(buf[0..len], tmp[i..]);
    return len;
}

/// Parse /etc/passwd and reload DB (called at mount time to pick up persisted users).
pub fn loadPasswd() void {
    const node = vfs.resolve("/etc/passwd") catch return;
    // Reset non-root entries.
    for (db[1..]) |*u| u.* = .{};
    var buf: [4096]u8 = undefined;
    const n = vfs.readAt(node, &buf, 0) catch return;
    var lines = std.mem.tokenizeScalar(u8, buf[0..n], '\n');
    while (lines.next()) |line| {
        // name:x:uid:gid::home:shell  — use splitScalar to preserve empty fields
        var fields: [7][]const u8 = [_][]const u8{""} ** 7;
        var fi: usize = 0;
        var fit = std.mem.splitScalar(u8, line, ':');
        while (fit.next()) |f| : (fi += 1) {
            if (fi < 7) fields[fi] = f;
        }
        if (fi < 7) continue;
        const uid = parseDec(fields[2]) orelse continue;
        const gid = parseDec(fields[3]) orelse continue;
        if (findByUid(uid) != null) continue; // already loaded (e.g. root)
        for (&db) |*u| {
            if (!u.used) {
                u.* = .{ .uid = uid, .gid = gid, .used = true };
                const nl = @min(fields[0].len, u.name.len - 1);
                @memcpy(u.name[0..nl], fields[0][0..nl]);
                const hl = @min(fields[5].len, u.home.len - 1);
                @memcpy(u.home[0..hl], fields[5][0..hl]);
                const sl = @min(fields[6].len, u.shell.len - 1);
                @memcpy(u.shell[0..sl], fields[6][0..sl]);
                if (uid >= next_uid) next_uid = uid + 1;
                break;
            }
        }
    }
}

fn parseDec(s: []const u8) ?u32 {
    if (s.len == 0) return null;
    var v: u32 = 0;
    for (s) |c| {
        if (c < '0' or c > '9') return null;
        v = v * 10 + (c - '0');
    }
    return v;
}
