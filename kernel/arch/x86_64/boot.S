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
    /* framebuffer request tag: type=5, ask GRUB for 1024x768x32 RGB */
    .align 8
    .word 5          /* type  */
    .word 0          /* flags (0 = required) */
    .long 20         /* size  */
    .long 1024       /* width  */
    .long 768        /* height */
    .long 32         /* depth  */
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
    /* GRUB: eax = multiboot2 magic, ebx = info struct address.
     * Stash them in edi/esi so they survive into the 64-bit ABI
     * (rdi = arg0, rsi = arg1). 32-bit writes zero the upper dword. */
    movl %eax, %edi
    movl %ebx, %esi

    movl $stack_top, %esp

    /* p4[0] -> p3 (present | writable) */
    movl $p3_table, %eax
    orl  $0x3, %eax
    movl %eax, p4_table

    /* p3[0..3] -> the four PD tables (present | writable) */
    xorl %ecx, %ecx
.fill_p3:
    movl %ecx, %edx
    shll $12, %edx                 /* edx = ecx * 4096 */
    movl $p2_tables, %eax
    addl %edx, %eax
    orl  $0x3, %eax
    movl %eax, p3_table(, %ecx, 8)
    incl %ecx
    cmpl $4, %ecx
    jne  .fill_p3

    /* Fill 2048 entries of 2 MiB huge pages -> identity map 0..4 GiB.
     * entry = (i * 2 MiB) | present | writable | huge.
     * 4 GiB covers high MMIO/framebuffer regions (e.g. ~0xFD000000). */
    xorl %ecx, %ecx
.fill_p2:
    movl $0x200000, %eax
    mul  %ecx                      /* edx:eax = 0x200000 * ecx (fits in eax) */
    orl  $0x83, %eax               /* present | writable | huge (PS) */
    movl %eax, p2_tables(, %ecx, 8) /* low dword; high dword stays 0 */
    incl %ecx
    cmpl $2048, %ecx
    jne  .fill_p2

    /* CR3 = p4 */
    movl $p4_table, %eax
    movl %eax, %cr3

    /* CR4.PAE = 1 */
    movl %cr4, %eax
    orl  $(1 << 5), %eax
    movl %eax, %cr4

    /* EFER.LME = 1 (MSR 0xC0000080, bit 8) */
    movl $0xC0000080, %ecx
    rdmsr
    orl  $(1 << 8), %eax
    wrmsr

    /* CR0.PG = 1 (paging on -> enter compatibility mode) */
    movl %cr0, %eax
    orl  $(1 << 31), %eax
    movl %eax, %cr0

    /* Load 64-bit GDT and far-jump to flush into true 64-bit mode */
    lgdt gdt64_pointer
    ljmp $0x08, $long_mode_start

/* ---- 64-bit entry -------------------------------------------------------- */
.code64
.type long_mode_start, @function
long_mode_start:
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
