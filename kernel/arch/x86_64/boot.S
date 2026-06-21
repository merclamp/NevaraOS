/* boot.S — Multiboot2 header + 32-bit -> 64-bit long mode trampoline.
 *
 * GRUB enters here in 32-bit protected mode (Multiboot2 spec). We must:
 *   1. set up a stack
 *   2. build identity-mapped page tables (first 1 GiB, 2 MiB huge pages)
 *   3. enable PAE, set EFER.LME, enable paging
 *   4. load a 64-bit GDT and far-jump into 64-bit code
 *   5. hand control to the Zig kmain(magic, info)
 */

/* ---- Multiboot2 header ---------------------------------------------------- */
.set MB2_MAGIC, 0xE85250D6        /* multiboot2 magic */
.set MB2_ARCH,  0                 /* 0 = i386 protected mode */
.set MB2_LEN,   mb2_end - mb2_start
.set MB2_CHECK, -(MB2_MAGIC + MB2_ARCH + MB2_LEN)

.section .multiboot, "a"
.align 8
mb2_start:
    .long MB2_MAGIC
    .long MB2_ARCH
    .long MB2_LEN
    .long MB2_CHECK
    /* Framebuffer request tag (type=5).
     * flags=1 → optional (don't abort if GRUB can't satisfy it).
     * width=0, height=0, depth=0 → let GRUB pick the best available mode.
     * The kernel accepts any resolution and 24/32-bpp. */
    .align 8
    .word 5          /* type  */
    .word 1          /* flags (1 = optional — boot even without framebuffer) */
    .long 20         /* size  */
    .long 0          /* width  (0 = any) */
    .long 0          /* height (0 = any) */
    .long 0          /* depth  (0 = any, kernel supports 24 and 32-bpp) */
    /* end tag: type=0, flags=0, size=8 */
    .align 8
    .word 0
    .word 0
    .long 8
mb2_end:

/* ---- Boot-time BSS: page tables + stack ---------------------------------- */
.section .bss, "aw", @nobits
.align 4096
p4_table:
    .skip 4096
p3_table:
    .skip 4096
p2_tables:
    .skip 4096 * 4    /* 4 PD tables -> identity map first 4 GiB */
.align 16
stack_bottom:
    .skip 16384
stack_top:

/* ---- 32-bit entry point -------------------------------------------------- */
.section .boot, "ax"
.code32
.global _start
.type _start, @function
_start:
    /* Save GRUB registers FIRST — before any eax clobber.
     * eax = 0x36d76289 (Multiboot2 magic), ebx = info struct ptr.
     * edi/esi survive the page-table loops; in 64-bit mode 32-bit
     * writes zero-extend into rdi/rsi (SysV AMD64 ABI). */
    movl %eax, %edi
    movl %ebx, %esi

    /* Diagnostic 'N' at VGA cell 0 — AFTER saving magic. */
    movl  $0x0E4E, %eax
    movl  $0xB8000, %ecx
    movw  %ax, (%ecx)

    movl $stack_top, %esp

    /* p4[0] -> p3 (present | writable). Use register-indirect to
     * avoid 64-bit displacement emitted for direct symbol refs. */
    movl $p3_table, %eax
    orl  $0x3, %eax
    movl $p4_table, %ecx
    movl %eax, (%ecx)

    /* p3[0..3] -> the four PD tables */
    xorl %ecx, %ecx
.fill_p3:
    movl %ecx, %edx
    shll $12, %edx
    movl $p2_tables, %eax
    addl %edx, %eax
    orl  $0x3, %eax
    movl $p3_table, %edx
    leal (%edx, %ecx, 8), %edx
    movl %eax, (%edx)
    movl $0, 4(%edx)
    incl %ecx
    cmpl $4, %ecx
    jne  .fill_p3

    /* 2048 x 2 MiB huge pages -> identity map 0..4 GiB */
    xorl %ecx, %ecx
.fill_p2:
    movl $0x200000, %eax
    mull %ecx
    orl  $0x83, %eax
    movl $p2_tables, %edx
    leal (%edx, %ecx, 8), %edx
    movl %eax, (%edx)
    movl $0, 4(%edx)
    incl %ecx
    cmpl $2048, %ecx
    jne  .fill_p2

    /* CR3 = p4_table */
    movl $p4_table, %eax
    movl %eax, %cr3

    /* Diagnostic 'A' at VGA cell 1 */
    movl  $0x0E41, %eax
    movl  $0xB8002, %ecx
    movw  %ax, (%ecx)

    /* CR4.PAE = 1 */
    movl %cr4, %eax
    orl  $(1 << 5), %eax
    movl %eax, %cr4

    /* EFER.LME = 1 */
    movl $0xC0000080, %ecx
    rdmsr
    orl  $(1 << 8), %eax
    wrmsr

    /* CR0.PG = 1 */
    movl %cr0, %eax
    orl  $(1 << 31), %eax
    movl %eax, %cr0

    /* Diagnostic 'R' at VGA cell 2 */
    movl  $0x0E52, %eax
    movl  $0xB8004, %ecx
    movw  %ax, (%ecx)

    /* Load 64-bit GDT and far-jump to true 64-bit mode */
    lgdt gdt64_pointer
    ljmp $0x08, $long_mode_start

/* ---- 64-bit entry -------------------------------------------------------- */
.code64
.type long_mode_start, @function
long_mode_start:
    /* Diagnostic: '!' at VGA cell 3 = reached 64-bit mode */
    movq  $0x0E21, %rax
    movq  $0xB8006, %rcx
    movw  %ax, (%rcx)

    /* Reload data segment registers with the null selector (flat model) */
    xorw %ax, %ax
    movw %ax, %ds
    movw %ax, %es
    movw %ax, %fs
    movw %ax, %gs
    movw %ax, %ss

    /* rdi = magic, rsi = info (set earlier as edi/esi) */
    call kmain

.hang:
    cli
    hlt
    jmp .hang

/* ---- 64-bit GDT ---------------------------------------------------------- */
.section .rodata, "a"
.align 8
gdt64:
    .quad 0                                                   /* null */
gdt64_code:
    /* exec | descriptor type (S) | present | long-mode (L) */
    .quad (1 << 43) | (1 << 44) | (1 << 47) | (1 << 53)
gdt64_pointer:
    .word gdt64_pointer - gdt64 - 1
    .quad gdt64
