/* Linker script for the Nevara OS kernel (x86_64, loaded at 1 MiB by GRUB). */

ENTRY(_start)

SECTIONS {
    /* GRUB loads the kernel image starting at the conventional 1 MiB mark. */
    . = 1M;

    /* Multiboot2 header must live within the first 32 KiB, 8-byte aligned. */
    .boot ALIGN(8) : {
        KEEP(*(.multiboot))
    }

    .text ALIGN(4K) : {
        *(.boot)
        *(.text .text.*)
    }

    .rodata ALIGN(4K) : {
        *(.rodata .rodata.*)
    }

    .data ALIGN(4K) : {
        *(.data .data.*)
    }

    .bss ALIGN(4K) : {
        *(COMMON)
        *(.bss .bss.*)
    }

    /* End of the loaded kernel image; the PMM places its bitmap after this. */
    . = ALIGN(4K);
    kernel_end = .;

    /* Drop sections we never want in a freestanding image. */
    /DISCARD/ : {
        *(.eh_frame)
        *(.note .note.*)
        *(.comment)
    }
}
