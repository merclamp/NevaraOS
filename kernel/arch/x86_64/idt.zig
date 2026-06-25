//! Interrupt Descriptor Table (x86_64).
//!
//! Installs interrupt gates for the 32 CPU exception vectors, pointing each at
//! the matching stub in isr.S. Hardware IRQs (PIC/APIC) come later; for now this
//! gives us real fault handling instead of silent triple faults.

const console = @import("console.zig");
const gdt = @import("gdt.zig");
const pic = @import("pic.zig");
const sched = @import("../../proc/sched.zig");
const kbd = @import("kbd.zig");
const pit = @import("pit.zig");
const rtl8139 = @import("../../net/rtl8139.zig");
const process = @import("../../proc/process.zig");


/// 64-bit IDT gate descriptor (16 bytes).
const IdtEntry = packed struct {
    offset_low: u16 = 0,
    selector: u16 = 0,
    ist: u8 = 0,
    type_attr: u8 = 0,
    offset_mid: u16 = 0,
    offset_high: u32 = 0,
    reserved: u32 = 0,
};

/// The `lidt` operand.
const IdtPointer = packed struct {
    limit: u16,
    base: u64,
};

/// Saved processor state at the point of an interrupt. Field order matches the
/// stack layout built by isr.S (r15 pushed last => lowest address).
pub const InterruptFrame = extern struct {
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
    vector: u64,
    error_code: u64,
    // Pushed by the CPU on interrupt entry:
    rip: u64,
    cs: u64,
    rflags: u64,
    rsp: u64,
    ss: u64,
};

const INTERRUPT_GATE: u8 = 0x8E; // present, DPL0, 64-bit interrupt gate

var idt: [256]IdtEntry = [_]IdtEntry{.{}} ** 256;
var idtr: IdtPointer = undefined;

/// Human-readable names for the architectural exceptions.
const exception_names = [_][]const u8{
    "Divide-by-Zero",
    "Debug",
    "Non-Maskable Interrupt",
    "Breakpoint",
    "Overflow",
    "Bound Range Exceeded",
    "Invalid Opcode",
    "Device Not Available",
    "Double Fault",
    "Coprocessor Segment Overrun",
    "Invalid TSS",
    "Segment Not Present",
    "Stack-Segment Fault",
    "General Protection Fault",
    "Page Fault",
    "Reserved",
    "x87 Floating-Point Exception",
    "Alignment Check",
    "Machine Check",
    "SIMD Floating-Point Exception",
    "Virtualization Exception",
    "Control Protection Exception",
    "Reserved",
    "Reserved",
    "Reserved",
    "Reserved",
    "Reserved",
    "Reserved",
    "Hypervisor Injection Exception",
    "VMM Communication Exception",
    "Security Exception",
    "Reserved",
};

fn setGate(vector: usize, handler: u64) void {
    idt[vector] = .{
        .offset_low = @truncate(handler),
        .selector = gdt.KERNEL_CODE,
        .ist = 0,
        .type_attr = INTERRUPT_GATE,
        .offset_mid = @truncate(handler >> 16),
        .offset_high = @truncate(handler >> 32),
        .reserved = 0,
    };
}

/// Install exception gates and load the IDT.
pub fn init() void {
    for (0..48) |vec| {
        setGate(vec, isr_stub_table[vec]);
    }

    idtr = .{
        .limit = @sizeOf(@TypeOf(idt)) - 1,
        .base = @intFromPtr(&idt),
    };
    idt_flush(&idtr);

    console.writeString("[idt] IDT loaded, 32 exceptions + 16 IRQ handlers installed\n");
}

/// Common entry point from isr.S for every CPU exception.
export fn isrHandler(frame: *InterruptFrame) callconv(.c) void {
    const vec = frame.vector;

    // Hardware IRQs (remapped PIC: vectors 32..47).
    if (vec >= 32 and vec <= 47) {
        const irq: u8 = @intCast(vec - 32);
        if (irq == 1)  kbd.onIrq();  // keyboard
        if (irq == 11) rtl8139.onIrq(); // network (RTL8139 on IRQ11)
        pic.sendEOI(irq);
        if (irq == 0) { pit.tick(); sched.preempt(); } // timer: tick + preempt
        return;
    }

    // Breakpoint (#BP) is recoverable: report and resume.
    if (vec == 3) {
        console.writeString("[isr] breakpoint (#BP) at rip=");
        console.writeHex(frame.rip);
        console.writeString(" -- resuming\n");
        return;
    }

    // A CPU exception taken in ring 3 is the user program's fault, not the
    // kernel's: kill it with SIGSEGV instead of bringing the machine down.
    if ((frame.cs & 3) == 3) {
        const p = process.current();
        console.writeString("[signal] PID ");
        console.writeDec(p.pid);
        console.writeString(" killed by SIGSEGV (");
        if (vec < exception_names.len) console.writeString(exception_names[vec]);
        console.writeString(") at rip=");
        console.writeHex(frame.rip);
        console.writeString("\n");
        process.exit(128 + 11); // 128 + SIGSEGV
    }

    console.writeString("\n*** CPU EXCEPTION ***\n");
    console.writeString("  vector: ");
    console.writeHex(vec);
    if (vec < exception_names.len) {
        console.writeString(" (");
        console.writeString(exception_names[vec]);
        console.writeString(")");
    }
    console.writeString("\n  error: ");
    console.writeHex(frame.error_code);
    console.writeString("\n  rip:   ");
    console.writeHex(frame.rip);
    console.writeString("\n  rsp:   ");
    console.writeHex(frame.rsp);
    console.writeString("\n  rflags:");
    console.writeHex(frame.rflags);
    console.writeString("\nHalting.\n");

    while (true) {
        asm volatile ("cli; hlt");
    }
}

// Provided by isr.S.
extern const isr_stub_table: [48]u64;
extern fn idt_flush(ptr: *const IdtPointer) void;
