//! Userspace bring-up: configure the SYSCALL/SYSRET MSRs, build a System V user
//! stack, and route user system calls to the kernel dispatcher. Ring-3 entry is
//! a one-way trip (`enter_user` / `user_return`); the only ways back to ring 0
//! are a syscall (which returns via the trap frame) or `exit` (which terminates
//! the process's kernel thread through the scheduler).

const console = @import("console.zig");
const pmm = @import("../../mm/pmm.zig");
const vmm = @import("../../mm/vmm.zig");
const syscall = @import("../../syscall/syscall.zig");
const signals = @import("../../proc/signals.zig");

// SYSCALL/SYSRET MSRs.
const MSR_EFER: u32 = 0xC000_0080;
const MSR_STAR: u32 = 0xC000_0081;
const MSR_LSTAR: u32 = 0xC000_0082;
const MSR_SFMASK: u32 = 0xC000_0084;

const EFER_SCE: u64 = 1 << 0; // System Call Extensions

/// Saved user register state at a syscall / interrupt. Layout matches the push
/// order in usermode.S (r15 lands at the lowest address).
pub const TrapFrame = extern struct {
    r15: u64,
    r14: u64,
    r13: u64,
    r12: u64,
    r11: u64,
    r10: u64,
    r9: u64,
    r8: u64,
    rbp: u64,
    rdi: u64,
    rsi: u64,
    rdx: u64,
    rcx: u64,
    rbx: u64,
    rax: u64,
    // iretq frame:
    rip: u64,
    cs: u64,
    rflags: u64,
    rsp: u64,
    ss: u64,
};

// Provided by usermode.S.
extern fn syscall_entry() callconv(.c) void;
pub extern fn enter_user(entry: usize, user_stack_top: usize) callconv(.c) noreturn;
pub extern fn user_return(tf: *const TrapFrame) callconv(.c) noreturn;

inline fn wrmsr(msr: u32, value: u64) void {
    asm volatile ("wrmsr"
        :
        : [eax] "{eax}" (@as(u32, @truncate(value))),
          [edx] "{edx}" (@as(u32, @truncate(value >> 32))),
          [ecx] "{ecx}" (msr),
    );
}

inline fn rdmsr(msr: u32) u64 {
    var lo: u32 = undefined;
    var hi: u32 = undefined;
    asm volatile ("rdmsr"
        : [lo] "={eax}" (lo),
          [hi] "={edx}" (hi),
        : [ecx] "{ecx}" (msr),
    );
    return (@as(u64, hi) << 32) | lo;
}

/// Entry point from syscall_entry (asm). Dispatches and writes the return value
/// back into the trap frame's rax; the asm path then iretq's to ring 3.
export fn syscall_from_user(tf: *TrapFrame) callconv(.c) void {
    tf.rax = @bitCast(syscall.handle(tf));
    // Deliver any pending signal before returning to ring 3. This may redirect
    // `tf` into a user handler, or terminate the process (noreturn).
    signals.deliver(tf);
}

/// Configure SYSCALL/SYSRET: segment selectors, the entry point, the RFLAGS
/// mask, and enable the extension.
pub fn init() void {
    // STAR[47:32] = kernel CS base (0x08) for SYSCALL.
    // STAR[63:48] = base for SYSRET: CS = base+16 (0x20), SS = base+8 (0x18).
    wrmsr(MSR_STAR, (@as(u64, 0x10) << 48) | (@as(u64, 0x08) << 32));
    wrmsr(MSR_LSTAR, @intFromPtr(&syscall_entry));
    wrmsr(MSR_SFMASK, 0x44700); // clear TF, IF, DF, NT, AC on syscall entry

    wrmsr(MSR_EFER, rdmsr(MSR_EFER) | EFER_SCE);

    console.writeString("[user] SYSCALL/SYSRET configured\n");
}

// User stack region for ELF-loaded programs (separate from their segments).
pub const ELF_STACK_TOP: usize = 0x4000_4000_0000;
const ELF_STACK_PAGES: usize = 4;

inline fn push(sp: *usize, value: u64) void {
    sp.* -= 8;
    @as(*u64, @ptrFromInt(sp.*)).* = value;
}

/// Map a user stack in the current address space and lay out the System V
/// process stack (argc, argv[], envp, auxv). Returns the initial user rsp, or
/// null on out-of-memory.
pub fn buildUserStack(args: []const []const u8) ?usize {
    const flags = vmm.PRESENT | vmm.WRITABLE | vmm.USER;
    var p: usize = 0;
    while (p < ELF_STACK_PAGES) : (p += 1) {
        const frame = pmm.alloc() orelse return null;
        if (!vmm.map(ELF_STACK_TOP - (p + 1) * 0x1000, frame, flags)) return null;
    }

    var sp: usize = ELF_STACK_TOP;

    var argv_ptrs: [16]usize = undefined;
    const n = @min(args.len, argv_ptrs.len);
    var i: usize = n;
    while (i > 0) {
        i -= 1;
        sp -= args[i].len + 1;
        const dst: [*]u8 = @ptrFromInt(sp);
        @memcpy(dst[0..args[i].len], args[i]);
        dst[args[i].len] = 0;
        argv_ptrs[i] = sp;
    }

    sp &= ~@as(usize, 0xF); // 16-align the string area boundary

    // Keep argc 16-aligned at entry: pushes below are auxv(2)+envp(1)+argv NULL(1)
    // + argv(n) + argc(1) = 5 + n.
    if (((5 + n) & 1) == 1) push(&sp, 0);

    push(&sp, 0); // auxv: AT_NULL
    push(&sp, 0);
    push(&sp, 0); // envp terminator
    push(&sp, 0); // argv terminator
    i = n;
    while (i > 0) {
        i -= 1;
        push(&sp, argv_ptrs[i]);
    }
    push(&sp, n); // argc

    return sp;
}
