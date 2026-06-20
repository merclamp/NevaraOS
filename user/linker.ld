/* Linker script for Nevara userspace programs.
 * Linked at a fixed high virtual base (64 TiB), well above the kernel's
 * identity-mapped region, so the loader can map fresh user pages there. */

ENTRY(_start)

SECTIONS {
    . = 0x400000000000;

    .text  : { *(.text .text.*) }
    .rodata : { *(.rodata .rodata.*) }
    .data  : { *(.data .data.*) }
    .bss   : { *(.bss .bss.*) *(COMMON) }

    /DISCARD/ : {
        *(.eh_frame)
        *(.note .note.*)
        *(.comment)
        *(.debug*)
    }
}
