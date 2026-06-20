//! Kernel thread scheduler.
//!
//! Stage 1 is cooperative round-robin: threads run until they call `yield()`.
//! Stage 2 (preemptive, timer-driven) builds on the same primitives.
//!
//! Each thread owns a kernel stack (from the heap). The first switch into a new
//! thread is bootstrapped by hand-crafting its stack so the `ret` at the end of
//! `context_switch` lands in `threadStart`, which then calls the entry function.

const console = @import("../arch/x86_64/console.zig");
const heap = @import("../mm/heap.zig");

pub const State = enum { ready, running, finished };

pub const Thread = struct {
    /// Saved stack pointer. Must be the field `context_switch` writes through.
    rsp: u64 = 0,
    id: u32 = 0,
    state: State = .ready,
    entry: ?*const fn () void = null,
    stack: []u8 = &.{},
};

const MAX_THREADS = 16;
const STACK_SIZE = 16 * 1024;

var threads: [MAX_THREADS]?*Thread = .{null} ** MAX_THREADS;
var count: usize = 0;
var current: *Thread = undefined;
var bootstrap: Thread = .{};
var next_id: u32 = 0;

extern fn context_switch(old_rsp: *u64, new_rsp: u64) void;

/// Register the current (kmain) execution context as the first thread.
pub fn init() void {
    bootstrap = .{ .id = next_id, .state = .running };
    next_id += 1;
    current = &bootstrap;
    threads[0] = &bootstrap;
    count = 1;
}

pub fn currentThread() *Thread {
    return current;
}

/// Trampoline every freshly created thread first returns into.
fn threadStart() callconv(.c) noreturn {
    if (current.entry) |e| e();
    finish();
}

fn finish() noreturn {
    current.state = .finished;
    while (true) yield();
}

/// Hand-craft a new thread's stack so the first context switch starts it.
fn initContext(t: *Thread) void {
    const top = (@intFromPtr(t.stack.ptr) + t.stack.len) & ~@as(usize, 0xF);
    // Layout matches context_switch's epilogue: pop 6 callee-saved regs, popfq,
    // then ret. Seed RFLAGS with IF set so new threads start preemptible. The
    // entry slot is 16-aligned so the entry function's rsp is ABI-aligned.
    const entry_slot = top - 16;
    @as(*u64, @ptrFromInt(entry_slot)).* = @intFromPtr(&threadStart);
    @as(*u64, @ptrFromInt(entry_slot - 8)).* = 0x202; // RFLAGS: IF + reserved bit
    var i: usize = 0;
    while (i < 6) : (i += 1) {
        @as(*u64, @ptrFromInt(entry_slot - 56 + i * 8)).* = 0; // r15..rbx
    }
    t.rsp = entry_slot - 56;
}

/// Create a new ready thread running `entry`.
pub fn spawn(entry: *const fn () void) !*Thread {
    const a = heap.allocator();
    const t = try a.create(Thread);
    const stack = try a.alloc(u8, STACK_SIZE);
    t.* = .{ .id = next_id, .state = .ready, .entry = entry, .stack = stack };
    next_id += 1;
    initContext(t);
    threads[count] = t;
    count += 1;
    return t;
}

fn currentIndex() usize {
    var i: usize = 0;
    while (i < count) : (i += 1) {
        if (threads[i].? == current) return i;
    }
    return 0;
}

fn pickNext() *Thread {
    const here = currentIndex();
    var n: usize = 1;
    while (n <= count) : (n += 1) {
        const cand = threads[(here + n) % count].?;
        if (cand.state == .ready) return cand;
    }
    return current;
}

/// Voluntarily give the CPU to the next ready thread.
pub fn yield() void {
    const prev = current;
    const next = pickNext();
    if (next == prev) return;
    if (prev.state == .running) prev.state = .ready;
    next.state = .running;
    current = next;
    context_switch(&prev.rsp, next.rsp);
}

/// Total timer ticks observed (for diagnostics).
pub var ticks: u64 = 0;

/// Called from the timer interrupt to preempt the running thread.
/// Runs with interrupts disabled (interrupt-gate context).
pub fn preempt() void {
    ticks += 1;
    yield();
}

/// Count threads (other than the bootstrap/kmain context) that can still run.
pub fn runnableOthers() usize {
    var c: usize = 0;
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const t = threads[i].?;
        if (t != &bootstrap and t.state != .finished) c += 1;
    }
    return c;
}
