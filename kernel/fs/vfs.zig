//! Virtual Filesystem layer + in-memory backing (tmpfs-style).
//!
//! A single in-RAM tree holds files, directories, and character devices. Files
//! grow their data buffer on demand from the kernel heap; directories keep a
//! growable list of children; char devices route reads/writes to driver ops.
//!
//! The root is populated from the ext4 image at boot. All create/unlink/write
//! operations that touch an ext4-backed node are propagated to ext4 on disk.
//! Pure tmpfs nodes (e.g. /dev entries, pipes) are RAM-only.

const std = @import("std");
const heap = @import("../mm/heap.zig");
const console = @import("../arch/x86_64/console.zig");
const tty = @import("../tty.zig");
const ext4 = @import("ext4.zig");

pub const Error = error{
    NotFound,
    NotDirectory,
    IsDirectory,
    NotEmpty,
    Exists,
    NotSupported,
    Invalid,
    OutOfMemory,
};

pub const Kind = enum { file, dir, chardev, pipe };

/// Anonymous pipe: a fixed-size ring buffer in kernel memory.
pub const Pipe = struct {
    const CAP = 4096;
    buf: [CAP]u8 = undefined,
    head: usize = 0,
    tail: usize = 0,
    writers: u32 = 1,

    pub fn avail(self: *const Pipe) usize { return (self.head -% self.tail) % CAP; }
    pub fn free(self: *const Pipe) usize  { return CAP - 1 - self.avail(); }
    pub fn push(self: *Pipe, b: u8) void  { self.buf[self.head % CAP] = b; self.head +%= 1; }
    pub fn pop(self: *Pipe) u8            { const b = self.buf[self.tail % CAP]; self.tail +%= 1; return b; }
};

pub const DevOps = struct {
    read:  *const fn (buf: []u8) usize,
    write: *const fn (buf: []const u8) usize,
};

pub const Node = struct {
    kind: Kind,
    name: []u8,
    parent: ?*Node = null,

    // Directory children list (heap-grown).
    children: []*Node = &.{},
    child_count: usize = 0,

    // Regular file data (heap buffer; `data.len` = capacity, `size` = logical).
    data: []u8 = &.{},
    size: usize = 0,

    // Character device.
    dev: ?*const DevOps = null,

    // ext4-backed node: on_ext=true means this node has a real inode on disk.
    // Reads are lazy-loaded into `data`. Writes go through to ext4.
    on_ext: bool = false,
    ext_ino: u32 = 0,

    // Anonymous pipe.
    pipe: ?*Pipe = null,
};

var alloc: std.mem.Allocator = undefined;
var root_node: *Node = undefined;

// ---- ext4 lazy-load ---------------------------------------------------------

fn loadExt(node: *Node) void {
    const buf = alloc.alloc(u8, node.size) catch return;
    // ext4 uses global scratch buffers (inobuf, blk, extblk) — disable
    // preemption for the duration so concurrent exec() calls can't race.
    asm volatile ("cli");
    _ = ext4.readFile(node.ext_ino, buf);
    asm volatile ("sti");
    node.data = buf;
}

/// Ensure file data is in RAM. Idempotent. Call before accessing node.data
/// directly (e.g. in exec / spawnImage).
pub fn ensureLoaded(node: *Node) void {
    if (node.kind != .file) return;
    if (node.data.len > 0 or node.size == 0) return;
    if (node.on_ext) loadExt(node);
}

// ---- ext4 population --------------------------------------------------------

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

pub fn mountExt4AsRoot() bool {
    if (!ext4.mount()) return false;
    root_node.on_ext = true;
    root_node.ext_ino = ext4.rootIno();
    populateExt(root_node, ext4.rootIno());
    console.writeString("[ext4] mounted as root filesystem\n");
    return true;
}

// ---- internal node helpers --------------------------------------------------

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

fn freeNode(node: *Node) void {
    alloc.free(node.name);
    if (node.data.len > 0) alloc.free(node.data);
    alloc.destroy(node);
}

// ---- public path API --------------------------------------------------------

pub fn lookup(dir: *Node, name: []const u8) ?*Node {
    if (dir.kind != .dir) return null;
    for (dir.children[0..dir.child_count]) |c| {
        if (std.mem.eql(u8, c.name, name)) return c;
    }
    return null;
}

pub fn root() *Node { return root_node; }

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

fn splitParent(path: []const u8) struct { parent: []const u8, name: []const u8 } {
    const idx = std.mem.lastIndexOfScalar(u8, path, '/') orelse
        return .{ .parent = "/", .name = path };
    const parent = if (idx == 0) "/" else path[0..idx];
    return .{ .parent = parent, .name = path[idx + 1 ..] };
}

// ---- create / mkdir / mkdev -------------------------------------------------

/// Create a node at `path`. If the parent is an ext4 directory, the new node
/// is also created in ext4 (for file and dir kinds).
pub fn create(path: []const u8, kind: Kind) Error!*Node {
    const parts = splitParent(path);
    if (parts.name.len == 0) return Error.Invalid;
    const parent = try resolve(parts.parent);
    if (parent.kind != .dir) return Error.NotDirectory;
    if (lookup(parent, parts.name) != null) return Error.Exists;

    const node = try makeNode(kind, parts.name);
    try addChild(parent, node);

    // If parent lives on ext4 and we're creating a real file or dir, persist it.
    if (parent.on_ext and parent.ext_ino != 0) {
        switch (kind) {
            .file => {
                const ino = ext4.createFile(parent.ext_ino, parts.name);
                if (ino != 0) { node.on_ext = true; node.ext_ino = ino; }
            },
            .dir => {
                const ino = ext4.createDir(parent.ext_ino, parts.name);
                if (ino != 0) { node.on_ext = true; node.ext_ino = ino; }
            },
            else => {},
        }
    }
    return node;
}

pub fn mkdir(path: []const u8) Error!*Node {
    return create(path, .dir);
}

pub fn mkdev(path: []const u8, ops: *const DevOps) Error!*Node {
    const node = try create(path, .chardev);
    node.dev = ops;
    return node;
}

// ---- unlink / rmdir / rename ------------------------------------------------

pub fn unlink(path: []const u8) Error!void {
    const parts = splitParent(path);
    if (parts.name.len == 0) return Error.Invalid;
    const parent = try resolve(parts.parent);
    if (parent.kind != .dir) return Error.NotDirectory;
    const node = lookup(parent, parts.name) orelse return Error.NotFound;
    if (node.kind == .dir) return Error.IsDirectory;

    // Persist to ext4 if backed.
    if (parent.on_ext and parent.ext_ino != 0 and node.on_ext) {
        _ = ext4.unlinkFile(parent.ext_ino, parts.name);
    }
    removeChild(parent, node);
    freeNode(node);
}

pub fn rmdir(path: []const u8) Error!void {
    const parts = splitParent(path);
    if (parts.name.len == 0) return Error.Invalid;
    const parent = try resolve(parts.parent);
    if (parent.kind != .dir) return Error.NotDirectory;
    const node = lookup(parent, parts.name) orelse return Error.NotFound;
    if (node.kind != .dir) return Error.NotDirectory;
    if (node.child_count > 0) return Error.NotEmpty;

    if (parent.on_ext and parent.ext_ino != 0 and node.on_ext) {
        // Use unlinkFile — rmdir on an empty dir removes its entry from parent.
        _ = ext4.unlinkFile(parent.ext_ino, parts.name);
    }
    removeChild(parent, node);
    freeNode(node);
}

pub fn rename(old_path: []const u8, new_path: []const u8) Error!void {
    const op = splitParent(old_path);
    const np = splitParent(new_path);
    if (op.name.len == 0 or np.name.len == 0) return Error.Invalid;
    const old_parent = try resolve(op.parent);
    const new_parent = try resolve(np.parent);
    if (old_parent.kind != .dir or new_parent.kind != .dir) return Error.NotDirectory;
    const node = lookup(old_parent, op.name) orelse return Error.NotFound;
    if (lookup(new_parent, np.name) != null) return Error.Exists;

    // Persist to ext4 if both parents are ext4-backed.
    if (old_parent.on_ext and old_parent.ext_ino != 0 and
        new_parent.on_ext and new_parent.ext_ino != 0 and node.on_ext)
    {
        _ = ext4.renameEntry(old_parent.ext_ino, op.name,
                             new_parent.ext_ino, np.name);
    }

    if (old_parent != new_parent) {
        removeChild(old_parent, node);
        try addChild(new_parent, node);
    }
    alloc.free(node.name);
    node.name = try dupName(np.name);
}

// ---- read / write -----------------------------------------------------------

pub fn readAt(node: *Node, buf: []u8, offset: usize) Error!usize {
    switch (node.kind) {
        .dir    => return Error.IsDirectory,
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
            // Lazy-load ext4 data on first read.
            if (node.on_ext and node.data.len == 0 and node.size > 0) loadExt(node);
            if (offset >= node.size) return 0;
            const n = @min(buf.len, node.size - offset);
            @memcpy(buf[0..n], node.data[offset .. offset + n]);
            return n;
        },
    }
}

pub fn writeAt(node: *Node, buf: []const u8, offset: usize) Error!usize {
    switch (node.kind) {
        .dir    => return Error.IsDirectory,
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

            // Grow in-memory buffer.
            if (end > node.data.len) {
                // For ext4 files, ensure we have the old content first.
                if (node.on_ext and node.data.len == 0 and node.size > 0) loadExt(node);
                var cap = if (node.data.len == 0) 64 else node.data.len;
                while (cap < end) cap *= 2;
                const grown = try alloc.alloc(u8, cap);
                if (node.size > 0 and node.data.len > 0)
                    @memcpy(grown[0..node.size], node.data[0..node.size]);
                if (node.data.len > 0) alloc.free(node.data);
                node.data = grown;
            }
            @memcpy(node.data[offset..end], buf);
            if (end > node.size) node.size = end;

            // Persist to ext4 if backed.
            if (node.on_ext and node.ext_ino != 0) {
                _ = ext4.writeFile(node.ext_ino, node.data[0..node.size]);
            }
            return buf.len;
        },
    }
}

pub fn readdir(dir: *Node, index: usize) ?*Node {
    if (dir.kind != .dir or index >= dir.child_count) return null;
    return dir.children[index];
}

// ---- /dev devices -----------------------------------------------------------

fn zeroRead(buf: []u8) usize  { @memset(buf, 0); return buf.len; }
fn nullRead(buf: []u8) usize  { _ = buf; return 0; }
fn sinkWrite(buf: []const u8) usize { return buf.len; }

const null_ops    = DevOps{ .read = nullRead,    .write = sinkWrite };
const zero_ops    = DevOps{ .read = zeroRead,    .write = sinkWrite };

fn consoleWrite(buf: []const u8) usize { console.writeString(buf); return buf.len; }
fn consoleRead(buf: []u8) usize        { return tty.readLine(buf); }
const console_ops = DevOps{ .read = consoleRead, .write = consoleWrite };

// ---- init / mkpipe ----------------------------------------------------------

pub fn init() Error!void {
    alloc = heap.allocator();
    root_node = try alloc.create(Node);
    root_node.* = .{ .kind = .dir, .name = try dupName("/") };

    _ = try mkdir("/dev");
    _ = try mkdev("/dev/null",    &null_ops);
    _ = try mkdev("/dev/zero",    &zero_ops);
    _ = try mkdev("/dev/console", &console_ops);
}

pub fn mkpipe() Error![2]*Node {
    const p = try alloc.create(Pipe);
    p.* = .{};
    const rend = try alloc.create(Node);
    rend.* = .{ .kind = .pipe, .name = try dupName("[pipe:r]"), .pipe = p };
    const wend = try alloc.create(Node);
    wend.* = .{ .kind = .pipe, .name = try dupName("[pipe:w]"), .pipe = p };
    return .{ rend, wend };
}
