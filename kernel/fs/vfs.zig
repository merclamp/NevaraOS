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
const ext4 = @import("ext4.zig");

pub const Error = error{
    NotFound,
    NotDirectory,
    IsDirectory,
    Exists,
    NotSupported,
    Invalid,
    OutOfMemory,
};

pub const Kind = enum { file, dir, chardev, pipe };

/// Anonymous pipe: a fixed-size ring buffer in kernel memory.
/// `writers` counts how many fd slots currently hold the write end. When it
/// drops to zero the read side sees EOF (returns 0).
pub const Pipe = struct {
    const CAP = 4096;
    buf: [CAP]u8 = undefined,
    head: usize = 0,   // write pos
    tail: usize = 0,   // read pos
    writers: u32 = 1,

    pub fn avail(self: *const Pipe) usize {
        return (self.head -% self.tail) % CAP;
    }
    pub fn free(self: *const Pipe) usize {
        return CAP - 1 - self.avail();
    }
    pub fn push(self: *Pipe, b: u8) void {
        self.buf[self.head % CAP] = b;
        self.head +%= 1;
    }
    pub fn pop(self: *Pipe) u8 {
        const b = self.buf[self.tail % CAP];
        self.tail +%= 1;
        return b;
    }
};

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

    // Read-only ext4 file/dir: lazily loaded into `data` on first read.
    on_ext: bool = false,
    ext_ino: u32 = 0,

    // Anonymous pipe.
    pipe: ?*Pipe = null,
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

/// fat.Dir handle for a disk-backed directory node.
fn fatDirOf(node: *Node) fat.Dir {
    return .{ .is_root = (mount_root != null and node == mount_root.?), .cluster = node.cluster };
}

/// Recursively populate `dirnode` from the FAT directory `fdir`.
fn populate(dirnode: *Node, fdir: fat.Dir) void {
    var i: usize = 0;
    while (fat.entryAt(fdir, i)) |e| : (i += 1) {
        const kind: Kind = if (e.is_dir) .dir else .file;
        const node = makeNode(kind, e.name[0..e.name_len]) catch return;
        node.on_disk = true;
        node.cluster = e.cluster;
        node.size = e.size;
        addChild(dirnode, node) catch return;
        if (e.is_dir) populate(node, .{ .is_root = false, .cluster = e.cluster });
    }
}

/// Mount the FAT disk at /mnt (formatting a fresh disk if needed) and populate
/// the whole tree (subdirectories included) from what's already on disk.
pub fn mountFat() void {
    if (!fat.mount()) {
        console.writeString("[fat] no disk to mount\n");
        return;
    }
    const m = mkdir("/mnt") catch return;
    m.on_disk = true;
    m.cluster = 0;
    mount_root = m;
    populate(m, fat.root());
    console.writeString("[fat] /mnt mounted\n");
}

/// Load a read-only ext4 file's contents into memory on first access.
fn loadExt(node: *Node) void {
    const buf = alloc.alloc(u8, node.size) catch return;
    _ = ext4.readFile(node.ext_ino, buf);
    node.data = buf;
}

/// Recursively populate `dirnode` from ext4 directory inode `ino`.
fn populateExt(dirnode: *Node, ino: u32) void {
    var i: usize = 0;
    while (ext4.entryAt(ino, i)) |e| : (i += 1) {
        const kind: Kind = if (e.is_dir) .dir else .file;
        const node = makeNode(kind, e.name[0..e.name_len]) catch return;
        node.on_ext = true;
        node.ext_ino = e.ino;
        if (!e.is_dir) node.size = ext4.sizeOf(e.ino);
        addChild(dirnode, node) catch return;
        if (e.is_dir) populateExt(node, e.ino);
    }
}

/// Mount the ext4 disk read-only at /ext.
pub fn mountExt4() void {
    if (!ext4.mount()) return;
    const m = mkdir("/ext") catch return;
    m.on_ext = true;
    m.ext_ino = 2; // root inode
    populateExt(m, 2);
    console.writeString("[ext4] /ext mounted (read-only)\n");
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
/// Remove `child` from `dir`'s children slice (shifts remaining entries left).
fn removeChild(dir: *Node, child: *Node) void {
    var i: usize = 0;
    while (i < dir.child_count) : (i += 1) {
        if (dir.children[i] == child) {
            var j = i;
            while (j + 1 < dir.child_count) : (j += 1)
                dir.children[j] = dir.children[j + 1];
            dir.child_count -= 1;
            return;
        }
    }
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
    if (parent.on_ext) return Error.NotSupported; // /ext is read-only
    if (lookup(parent, parts.name) != null) return Error.Exists;
    const node = try makeNode(kind, parts.name);
    try addChild(parent, node);
    if (parent.on_disk and parent.kind == .dir) {
        const pdir = fatDirOf(parent);
        node.on_disk = true;
        if (kind == .file) {
            node.cluster = 0;
            _ = fat.writeFileIn(pdir, node.name, "");
        } else if (kind == .dir) {
            if (fat.mkdirIn(pdir, node.name)) |e| {
                node.cluster = e.cluster;
            } else {
                node.on_disk = false;
            }
        }
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

/// Delete a non-directory node at `path`, updating FAT if on disk.
pub fn unlink(path: []const u8) Error!void {
    const parts = splitParent(path);
    if (parts.name.len == 0) return Error.Invalid;
    const parent = try resolve(parts.parent);
    if (parent.kind != .dir) return Error.NotDirectory;
    if (parent.on_ext) return Error.NotSupported;
    const node = lookup(parent, parts.name) orelse return Error.NotFound;
    if (node.kind == .dir) return Error.IsDirectory;
    if (node.on_disk) _ = fat.removeFileIn(fatDirOf(parent), node.name);
    removeChild(parent, node);
    alloc.free(node.name);
    if (node.data.len > 0) alloc.free(node.data);
    alloc.destroy(node);
}

/// Rename / move a node. Cross-directory FAT renames are not supported.
pub fn rename(old_path: []const u8, new_path: []const u8) Error!void {
    const op = splitParent(old_path);
    const np = splitParent(new_path);
    if (op.name.len == 0 or np.name.len == 0) return Error.Invalid;
    const old_parent = try resolve(op.parent);
    const new_parent = try resolve(np.parent);
    if (old_parent.kind != .dir or new_parent.kind != .dir) return Error.NotDirectory;
    if (old_parent.on_ext or new_parent.on_ext) return Error.NotSupported;
    const node = lookup(old_parent, op.name) orelse return Error.NotFound;
    if (lookup(new_parent, np.name) != null) return Error.Exists;
    if (node.on_disk and old_parent != new_parent) return Error.NotSupported;
    if (node.on_disk and node.kind == .file)
        _ = fat.renameFileIn(fatDirOf(old_parent), op.name, np.name);
    if (old_parent != new_parent) {
        removeChild(old_parent, node);
        try addChild(new_parent, node);
    }
    alloc.free(node.name);
    node.name = try dupName(np.name);
}

/// Read up to `buf.len` bytes from `node` at `offset`.
pub fn readAt(node: *Node, buf: []u8, offset: usize) Error!usize {
    switch (node.kind) {
        .dir => return Error.IsDirectory,
        .chardev => return (node.dev orelse return Error.NotSupported).read(buf),
        .pipe => {
            const p = node.pipe orelse return Error.NotSupported;
            asm volatile ("sti");
            while (p.avail() == 0) {
                if (p.writers == 0) { asm volatile ("cli"); return 0; }
                asm volatile ("hlt");
            }
            asm volatile ("cli");
            var n: usize = 0;
            while (n < buf.len and p.avail() > 0) : (n += 1) buf[n] = p.pop();

            return n;
        },
        .file => {
            if (node.on_disk and node.data.len == 0 and node.size > 0) loadDisk(node);
            if (node.on_ext and node.data.len == 0 and node.size > 0) loadExt(node);
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
        .pipe => {
            const p = node.pipe orelse return Error.NotSupported;
            var written: usize = 0;
            while (written < buf.len) {
                asm volatile ("sti");
                while (p.free() == 0) asm volatile ("hlt");
                asm volatile ("cli");
                while (written < buf.len and p.free() > 0) : (written += 1)
                    p.push(buf[written]);
            }
            return buf.len;
        },
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
            if (node.on_ext) return Error.NotSupported; // read-only ext4
            if (node.on_disk and node.parent != null)
                _ = fat.writeFileIn(fatDirOf(node.parent.?), node.name, node.data[0..node.size]);
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

/// Create an anonymous pipe. Returns two nodes: [0]=read-end, [1]=write-end.
/// Both share the same Pipe object. Closing all write-end fds signals EOF.
pub fn mkpipe() Error![2]*Node {
    const p = try alloc.create(Pipe);
    p.* = .{};

    const rend = try alloc.create(Node);
    rend.* = .{ .kind = .pipe, .name = try dupName("[pipe:r]"), .pipe = p };

    const wend = try alloc.create(Node);
    wend.* = .{ .kind = .pipe, .name = try dupName("[pipe:w]"), .pipe = p };

    return .{ rend, wend };
}
