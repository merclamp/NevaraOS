//! Virtual Filesystem layer + in-memory backing (tmpfs-style).
//!
//! A single in-RAM tree holds files, directories, and character devices. Files
//! grow their data buffer on demand from the kernel heap; directories keep a
//! growable list of children; char devices route reads/writes to driver ops.
//! This is the first filesystem; disk-backed filesystems will plug in behind
//! the same node interface later.

const std = @import("std");
const heap = @import("../mm/heap.zig");
const console = @import("../arch/x86_64/console.zig");
const tty = @import("../tty.zig");
const fat = @import("fat.zig");

pub const Error = error{
    NotFound,
    NotDirectory,
    IsDirectory,
    Exists,
    NotSupported,
    Invalid,
    OutOfMemory,
};

pub const Kind = enum { file, dir, chardev };

/// Character-device operations (e.g. /dev/null, /dev/zero).
pub const DevOps = struct {
    read: *const fn (buf: []u8) usize,
    write: *const fn (buf: []const u8) usize,
};

pub const Node = struct {
    kind: Kind,
    name: []u8,
    parent: ?*Node = null,

    // Directory: children list (heap-grown; `children.len` is capacity).
    children: []*Node = &.{},
    child_count: usize = 0,

    // Regular file: data buffer (`data.len` is capacity, `size` is logical len).
    data: []u8 = &.{},
    size: usize = 0,

    // Character device.
    dev: ?*const DevOps = null,

    // Disk-backed (FAT) file: lazily loaded into `data` on first read, and
    // written back to disk on every write.
    on_disk: bool = false,
    cluster: u16 = 0,
};

var alloc: std.mem.Allocator = undefined;
var root_node: *Node = undefined;
var mount_root: ?*Node = null;

/// Load a disk-backed file's contents into memory on first access.
fn loadDisk(node: *Node) void {
    const buf = alloc.alloc(u8, node.size) catch return;
    _ = fat.readFile(node.cluster, @intCast(node.size), buf);
    node.data = buf;
}

/// Callback for fat.forEachRoot: add a disk-backed child node for each file.
fn addDiskChild(dir: *Node, name: []const u8, cluster: u16, fsize: u32) void {
    const node = makeNode(.file, name) catch return;
    node.on_disk = true;
    node.cluster = cluster;
    node.size = fsize;
    addChild(dir, node) catch return;
}

/// Mount the FAT disk at /mnt (formatting a fresh disk if needed) and populate
/// it with the files already on disk.
pub fn mountFat() void {
    if (!fat.mount()) {
        console.writeString("[fat] no disk to mount\n");
        return;
    }
    const m = mkdir("/mnt") catch return;
    mount_root = m;
    fat.forEachRoot(m, addDiskChild);
    console.writeString("[fat] /mnt mounted\n");
}

fn dupName(s: []const u8) Error![]u8 {
    const m = try alloc.alloc(u8, s.len);
    @memcpy(m, s);
    return m;
}

fn makeNode(kind: Kind, name: []const u8) Error!*Node {
    const n = try alloc.create(Node);
    n.* = .{ .kind = kind, .name = try dupName(name) };
    return n;
}

fn addChild(dir: *Node, child: *Node) Error!void {
    if (dir.child_count == dir.children.len) {
        const new_cap = if (dir.children.len == 0) 4 else dir.children.len * 2;
        const buf = try alloc.alloc(*Node, new_cap);
        for (dir.children[0..dir.child_count], 0..) |c, i| buf[i] = c;
        if (dir.children.len > 0) alloc.free(dir.children);
        dir.children = buf;
    }
    dir.children[dir.child_count] = child;
    dir.child_count += 1;
    child.parent = dir;
}

/// Find a direct child by name.
pub fn lookup(dir: *Node, name: []const u8) ?*Node {
    if (dir.kind != .dir) return null;
    for (dir.children[0..dir.child_count]) |c| {
        if (std.mem.eql(u8, c.name, name)) return c;
    }
    return null;
}

pub fn root() *Node {
    return root_node;
}

/// Resolve an absolute path to a node.
pub fn resolve(path: []const u8) Error!*Node {
    if (path.len == 0 or path[0] != '/') return Error.Invalid;
    var cur = root_node;
    var it = std.mem.tokenizeScalar(u8, path, '/');
    while (it.next()) |comp| {
        if (cur.kind != .dir) return Error.NotDirectory;
        cur = lookup(cur, comp) orelse return Error.NotFound;
    }
    return cur;
}

/// Split a path into (parent dir path, final component).
fn splitParent(path: []const u8) struct { parent: []const u8, name: []const u8 } {
    const idx = std.mem.lastIndexOfScalar(u8, path, '/') orelse return .{ .parent = "/", .name = path };
    const parent = if (idx == 0) "/" else path[0..idx];
    return .{ .parent = parent, .name = path[idx + 1 ..] };
}

/// Create a node of `kind` at `path`. The parent directory must exist.
pub fn create(path: []const u8, kind: Kind) Error!*Node {
    const parts = splitParent(path);
    if (parts.name.len == 0) return Error.Invalid;
    const parent = try resolve(parts.parent);
    if (parent.kind != .dir) return Error.NotDirectory;
    if (lookup(parent, parts.name) != null) return Error.Exists;
    const node = try makeNode(kind, parts.name);
    try addChild(parent, node);
    if (kind == .file and mount_root != null and parent == mount_root.?) {
        node.on_disk = true;
        _ = fat.writeFile(node.name, "");
    }
    return node;
}

pub fn mkdir(path: []const u8) Error!*Node {
    return create(path, .dir);
}

/// Create a character device at `path` backed by `ops`.
pub fn mkdev(path: []const u8, ops: *const DevOps) Error!*Node {
    const node = try create(path, .chardev);
    node.dev = ops;
    return node;
}

/// Read up to `buf.len` bytes from `node` at `offset`.
pub fn readAt(node: *Node, buf: []u8, offset: usize) Error!usize {
    switch (node.kind) {
        .dir => return Error.IsDirectory,
        .chardev => return (node.dev orelse return Error.NotSupported).read(buf),
        .file => {
            if (node.on_disk and node.data.len == 0 and node.size > 0) loadDisk(node);
            if (offset >= node.size) return 0;
            const n = @min(buf.len, node.size - offset);
            @memcpy(buf[0..n], node.data[offset .. offset + n]);
            return n;
        },
    }
}

/// Write `buf` to `node` at `offset`, growing a regular file as needed.
pub fn writeAt(node: *Node, buf: []const u8, offset: usize) Error!usize {
    switch (node.kind) {
        .dir => return Error.IsDirectory,
        .chardev => return (node.dev orelse return Error.NotSupported).write(buf),
        .file => {
            const end = offset + buf.len;
            if (end > node.data.len) {
                var cap = if (node.data.len == 0) 64 else node.data.len;
                while (cap < end) cap *= 2;
                const grown = try alloc.alloc(u8, cap);
                @memcpy(grown[0..node.size], node.data[0..node.size]);
                if (node.data.len > 0) alloc.free(node.data);
                node.data = grown;
            }
            @memcpy(node.data[offset..end], buf);
            if (end > node.size) node.size = end;
            if (node.on_disk) _ = fat.writeFile(node.name, node.data[0..node.size]);
            return buf.len;
        },
    }
}

/// Return the `index`-th child of a directory, or null past the end.
pub fn readdir(dir: *Node, index: usize) ?*Node {
    if (dir.kind != .dir or index >= dir.child_count) return null;
    return dir.children[index];
}

// ---- /dev character devices -------------------------------------------------

fn zeroRead(buf: []u8) usize {
    @memset(buf, 0);
    return buf.len;
}
fn nullRead(buf: []u8) usize {
    _ = buf;
    return 0;
}
fn sinkWrite(buf: []const u8) usize {
    return buf.len;
}

const null_ops = DevOps{ .read = nullRead, .write = sinkWrite };
const zero_ops = DevOps{ .read = zeroRead, .write = sinkWrite };

fn consoleWrite(buf: []const u8) usize {
    console.writeString(buf);
    return buf.len;
}
fn consoleRead(buf: []u8) usize {
    return tty.readLine(buf);
}
const console_ops = DevOps{ .read = consoleRead, .write = consoleWrite };

/// Initialize the VFS: create the root and a minimal /dev.
pub fn init() Error!void {
    alloc = heap.allocator();
    root_node = try alloc.create(Node);
    root_node.* = .{ .kind = .dir, .name = try dupName("/") };

    _ = try mkdir("/dev");
    _ = try mkdev("/dev/null", &null_ops);
    _ = try mkdev("/dev/zero", &zero_ops);
    _ = try mkdev("/dev/console", &console_ops);
}
