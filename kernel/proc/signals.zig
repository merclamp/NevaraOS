//! POSIX-subset signals.
//!
//! Each process carries a pending-signal bitmask and a per-signal disposition
//! table (SIG_DFL / SIG_IGN / a user handler address). Signals are *delivered*
//! on the way back to ring 3:
//!   * from a normal syscall (usermode.syscall_from_user → deliver), and
//!   * from a blocked kernel wait (tty read, wait4, sleep → checkBlocked), which
//!     can only honour terminating dispositions (no handler frame from there).
//!
//! A caught signal runs a user handler with a frame built on the user stack and
//! a return through SYS_sigreturn (the restorer trampoline lives in nstd/zlibc
//! and is registered via SYS_signal). We use System-V one-shot semantics: the
//! disposition resets to SIG_DFL before the handler runs, so a handler must
//! re-arm itself and a fault inside a fault terminates instead of looping.

const process = @import("process.zig");
const usermode = @import("../arch/x86_64/usermode.zig");

pub const NSIG: u32 = 32;

// Dispositions stored in Process.sig_handlers[sig].
pub const SIG_DFL: u64 = 0;
pub const SIG_IGN: u64 = 1;

// Signal numbers (Linux values, subset).
pub const SIGHUP: u32 = 1;
pub const SIGINT: u32 = 2;
pub const SIGQUIT: u32 = 3;
pub const SIGILL: u32 = 4;
pub const SIGABRT: u32 = 6;
pub const SIGFPE: u32 = 8;
pub const SIGKILL: u32 = 9;
pub const SIGUSR1: u32 = 10;
pub const SIGSEGV: u32 = 11;
pub const SIGUSR2: u32 = 12;
pub const SIGPIPE: u32 = 13;
pub const SIGALRM: u32 = 14;
pub const SIGTERM: u32 = 15;
pub const SIGCHLD: u32 = 17;
pub const SIGCONT: u32 = 18;

/// Default action for a signal with SIG_DFL disposition: true = terminate the
/// process, false = ignore. (SIGKILL is handled separately and is uncatchable.)
fn defaultTerminate(sig: u32) bool {
    return switch (sig) {
        SIGCHLD, SIGCONT => false, // ignored by default
        else => true,
    };
}

/// Mark `sig` pending on `target`. Actual action happens when the target next
/// returns to user space or checks while blocked.
pub fn post(target: *process.Process, sig: u32) void {
    if (sig == 0 or sig >= NSIG) return;
    target.sig_pending |= (@as(u32, 1) << @intCast(sig));
}

/// Terminate the *current* process because of `sig`. noreturn.
fn terminate(sig: u32) noreturn {
    process.exit(128 + @as(i32, @intCast(sig)));
}

/// Build a signal-handler frame on the user stack and redirect `tf` so the
/// iretq back to ring 3 lands in the handler. On handler return, the restorer
/// trampoline issues SYS_sigreturn, which restores the saved frame.
fn setupFrame(tf: *usermode.TrapFrame, p: *process.Process, sig: u32, handler: u64) void {
    var sp: usize = tf.rsp;
    sp -= 128; // skip the System-V red zone
    sp &= ~@as(usize, 0xF);
    sp -= @sizeOf(usermode.TrapFrame);
    sp &= ~@as(usize, 0xF); // 16-align the saved-frame address
    const frame_addr = sp;

    const saved: *usermode.TrapFrame = @ptrFromInt(frame_addr);
    saved.* = tf.*; // snapshot for sigreturn

    // Return-address slot sits just below the saved frame, so that after the
    // handler's `ret` the restorer runs with rsp == frame_addr (== &saved).
    const ret_slot = frame_addr - 8;
    @as(*u64, @ptrFromInt(ret_slot)).* = p.sig_restorer;

    tf.rip = handler;
    tf.rdi = sig; // System V arg0: the signal number
    tf.rsp = ret_slot;
}

/// Deliver at most one pending signal on the syscall-return path. May invoke a
/// user handler (returns, with `tf` pointing at it) or terminate (noreturn).
pub fn deliver(tf: *usermode.TrapFrame) void {
    const p = process.current();
    while (p.sig_pending != 0) {
        const sig: u32 = @ctz(p.sig_pending);
        const bit = @as(u32, 1) << @intCast(sig);
        p.sig_pending &= ~bit;

        if (sig == SIGKILL) terminate(sig);
        const h = p.sig_handlers[sig];
        if (h == SIG_IGN) continue;
        if (h == SIG_DFL) {
            if (defaultTerminate(sig)) terminate(sig);
            continue; // default-ignore
        }
        // Caught: one-shot reset, then enter the handler.
        p.sig_handlers[sig] = SIG_DFL;
        setupFrame(tf, p, sig, h);
        return;
    }
}

/// Called from blocking kernel waits. Honours only terminating dispositions
/// (and drops ignored ones); caught handlers stay pending until the syscall
/// can return normally. noreturn if the process is terminated.
pub fn checkBlocked() void {
    const p = process.current();
    if (p.sig_pending == 0) return;
    var mask = p.sig_pending;
    while (mask != 0) {
        const sig: u32 = @ctz(mask);
        const bit = @as(u32, 1) << @intCast(sig);
        mask &= ~bit;

        if (sig == SIGKILL) terminate(sig);
        const h = p.sig_handlers[sig];
        if (h == SIG_IGN) {
            p.sig_pending &= ~bit;
            continue;
        }
        if (h == SIG_DFL) {
            if (defaultTerminate(sig)) terminate(sig);
            p.sig_pending &= ~bit; // default-ignore: drop it
        }
        // Caught handler: leave pending; it runs on the next syscall return.
    }
}
