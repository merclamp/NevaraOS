/* flush.S — load GDT/TSS and reload segment registers.
 *
 * Kept in real assembly because Zig 0.16's inline-asm validator rejects the
 * AT&T memory operands and rip-relative local labels these need.
 */

.section .text

/* void gdt_flush(const GdtPointer *ptr);  ptr in %rdi */
.global gdt_flush
.type gdt_flush, @function
gdt_flush:
    lgdt (%rdi)

    /* Reload the data segment registers with the kernel data selector. */
    movw $0x10, %ax
    movw %ax, %ds
    movw %ax, %es
    movw %ax, %fs
    movw %ax, %gs
    movw %ax, %ss

    /* Reload CS via a far return: pop return addr, push CS:addr, lretq. */
    popq %rax
    pushq $0x08          /* kernel code selector */
    pushq %rax
    lretq

/* void tss_flush(uint16_t selector);  selector in %di */
.global tss_flush
.type tss_flush, @function
tss_flush:
    ltr %di
    ret

/* void idt_flush(const IdtPointer *ptr);  ptr in %rdi */
.global idt_flush
.type idt_flush, @function
idt_flush:
    lidt (%rdi)
    ret

/* void invlpg(uint64_t virt);  virt in %rdi */
.global invlpg
.type invlpg, @function
invlpg:
    invlpg (%rdi)
    ret
