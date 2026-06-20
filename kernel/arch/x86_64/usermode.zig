//! Userspace bring-up: configure the SYSCALL/SYSRET MSRs, drop to ring 3, and
//! route user system calls to the kernel dispatcher.

const console = @import("console.zig");
const pmm = @import("../../mm/pmm.zig");
const vmm = @import("../../mm/vmm.zig");
const syscall = @import("../../syscall/syscall.zig");
const elf = @import("../../exec/elf.zig");

// SYSCALL/SYSRET MSRs.
const MSR_EFER: u32 = 0xC000_0080;
const MSR_STAR: u32 = 0xC000_0081;
const MSR_LSTAR: u32 = 0xC000_0082;
const MSR_SFMASK: u32 = 0xC000_0084;

const EFER_SCE: u64 = 1 << 0; // System Call Extensions

// User address space for the first ring-3 payload (well above the identity map).
const USER_CODE: usize = 0x4000_0000_0000;
const USER_STACK_TOP: usize = USER_CODE + 0x10_0000; // 1 MiB above the code page

// Provided by usermode.S.
extern fn syscall_entry() callconv(.c) void;
extern fn enter_user(entry: usize, user_stack_top: usize) void;
extern fn return_to_kernel(code: i32) noreturn;
extern var kernel_rsp: u64;
extern const syscall_stack_top: u8;

// Provided by user_payload.S.
extern const user_payload_start: u8;
extern const user_payload_end: u8;

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

/// Entry point for user system calls (called from syscall_entry in asm).
/// `exit` unwinds back to the kernel; everything else goes to the dispatcher.
export fn syscall_dispatch(num: usize, a1: usize, a2: usize, a3: usize) callconv(.c) isize {
    if (num == 60) {
        last_exit_code = @bitCast(@as(i32, @truncate(@as(isize, @bitCast(a1)))));
        return_to_kernel(last_exit_code); // exit: unwind to spawnImage / kmain
    }
    return syscall.dispatch(num, a1, a2, a3);
}

/// Exit code of the most recently finished user program.
pub var last_exit_code: i32 = 0;

/// Configure SYSCALL/SYSRET: segment selectors, the entry point, the RFLAGS
/// mask, and enable the extension.
pub fn init() void {
    kernel_rsp = @intFromPtr(&syscall_stack_top);

    // STAR[47:32] = kernel CS base (0x08) for SYSCALL.
    // STAR[63:48] = base for SYSRET: CS = base+16 (0x20), SS = base+8 (0x18).
    wrmsr(MSR_STAR, (@as(u64, 0x10) << 48) | (@as(u64, 0x08) << 32));
    wrmsr(MSR_LSTAR, @intFromPtr(&syscall_entry));
    wrmsr(MSR_SFMASK, 0x200); // clear IF on syscall entry

    wrmsr(MSR_EFER, rdmsr(MSR_EFER) | EFER_SCE);

    console.writeString("[user] SYSCALL/SYSRET configured\n");
}

/// Load the raw ring-3 payload into a user page and run it until it exits.
pub fn run() void {
    const flags = vmm.PRESENT | vmm.WRITABLE | vmm.USER;

    // Map and fill the code page.
    const code_frame = pmm.alloc() orelse return;
    if (!vmm.map(USER_CODE, code_frame, flags)) return;
    const start = @intFromPtr(&user_payload_start);
    const len = @intFromPtr(&user_payload_end) - start;
    const src: [*]const u8 = @ptrFromInt(start);
    const dst: [*]u8 = @ptrFromInt(USER_CODE);
    @memcpy(dst[0..len], src[0..len]);

    // Map a user stack page just below the stack top.
    const stack_frame = pmm.alloc() orelse return;
    if (!vmm.map(USER_STACK_TOP - 0x1000, stack_frame, flags)) return;

    console.writeString("[user] entering ring 3...\n");
    enter_user(USER_CODE, USER_STACK_TOP);
    console.writeString("[user] returned to kernel after exit\n");
}

// Stack for ELF-loaded programs (separate from their code/data segments).
const ELF_STACK_TOP: usize = 0x4000_4000_0000;
const ELF_STACK_PAGES: usize = 4;

inline fn push(sp: *usize, value: u64) void {
    sp.* -= 8;
    @as(*u64, @ptrFromInt(sp.*)).* = value;
}

/// Map a user stack, lay out the System V process stack (argc, argv[], envp,
/// auxv), and enter ring 3 at `entry`. Returns when the program exits.
pub fn runEntry(entry: usize, args: []const []const u8) void {
    const flags = vmm.PRESENT | vmm.WRITABLE | vmm.USER;
    var p: usize = 0;
    while (p < ELF_STACK_PAGES) : (p += 1) {
        const frame = pmm.alloc() orelse return;
        if (!vmm.map(ELF_STACK_TOP - (p + 1) * 0x1000, frame, flags)) return;
    }

    var sp: usize = ELF_STACK_TOP;

    // Copy the argument strings near the top of the stack.
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

    // Keep argc 16-aligned at entry: pad if the number of pushes is odd.
    // Pushes below: auxv(2) + envp NULL(1) + argv NULL(1) + argv(n) + argc(1).
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

    enter_user(entry, sp);
}

// ---- Process spawning (per-process address space) ---------------------------

const MAX_DEPTH = 8;
var spawn_depth: usize = 0;
var kstacks: [MAX_DEPTH][16 * 1024]u8 align(16) = undefined;

extern var user_rsp: u64;
extern var kernel_saved_rsp: u64;

/// Run `image` as an isolated process: a fresh address space (sharing the
/// kernel), its own kernel syscall stack, and its own brk. Synchronous — runs
/// the program to completion and returns its exit code. Context globals are
/// saved/restored so spawns can nest.
pub fn spawnImage(image: []const u8, args: []const []const u8) i32 {
    if (spawn_depth >= MAX_DEPTH) return -1;

    const saved_user = user_rsp;
    const saved_kctx = kernel_saved_rsp;
    const saved_krsp = kernel_rsp;
    const old_cr3 = vmm.currentCr3();

    const space = vmm.createAddressSpace() orelse return -1;
    vmm.switchTo(space);

    kernel_rsp = @intFromPtr(&kstacks[spawn_depth]) + kstacks[spawn_depth].len;
    spawn_depth += 1;
    syscall.resetBrk();

    if (elf.load(image)) |entry| {
        runEntry(entry, args);
    } else {
        last_exit_code = -1;
    }
    const code = last_exit_code;

    spawn_depth -= 1;
    vmm.switchTo(old_cr3);
    user_rsp = saved_user;
    kernel_saved_rsp = saved_kctx;
    kernel_rsp = saved_krsp;
    return code;
}
