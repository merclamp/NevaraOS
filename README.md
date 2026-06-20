# Nevara OS

> ⚠️ **Status: early development.** Nevara OS is a hobby operating system being
> built from scratch. It is **not** usable as a daily system yet — right now it
> boots, sets up the CPU, manages memory, and prints to the screen. Expect
> breaking changes, rewrites, and rough edges.

🇬🇧 English · [🇷🇺 Русский](README.ru.md)

---

Nevara OS is a modern operating system written in [Zig](https://ziglang.org),
created as a learning project and a long-term attempt to build a free,
independent OS — from the bootloader handoff all the way up to a usable
userland.

The name **Nevara** comes from the Neva river in Saint Petersburg, the author's
home city.

## Philosophy

Nevara OS is built on the idea of **truly free software** — freedom without
conditions.

- **Yours to use** — run it for anything, with no restrictions.
- **Yours to study** — every line of source is open.
- **Yours to change** — forking is a right, not a violation.
- **Yours to share** — pass it on, original or modified.

And a few promises that come with it:

- **No telemetry.** The system never collects data about you.
- **No backdoors.** All code is auditable.
- **No proprietary blobs.** Nothing ships without its source.
- **Reproducible.** The same source produces the same binary.

Licensed under the **MIT license** — chosen so Nevara can be a foundation for
*any* project (commercial, embedded, educational) without strings attached.

## Highlights

- Written entirely in Zig, with an explicit, no-surprises design.
- Boots on standard PCs via GRUB.
- Its own graphical text console (1024×768) — readable on a real monitor.
- A clean, modular kernel where every piece is meant to be understandable.

## Current status

Two foundational stages are done and verified in QEMU:

- ✅ **Boot & bring-up** — boots through GRUB into 64-bit mode, sets up the CPU
  (segments, interrupt/exception handling), reads the machine's memory layout,
  and renders output to the screen.
- ✅ **Memory management** — tracks all physical RAM, manages virtual memory
  (page tables), and provides a growing kernel heap.
- ✅ **Processes & scheduling** — kernel threads with context switching and a
  preemptive, timer-driven round-robin scheduler.

## Roadmap

What still needs to be built (roughly in order):

- ⏳ **Filesystem & system calls** — a virtual filesystem layer and the first
  Linux-compatible system calls.
- ⏳ **Userland** — loading and running real programs, an init system, a shell.
- ⏳ **Real filesystems** — reading and writing actual disks.
- ⏳ **Linux compatibility** — running unmodified Linux programs.
- ⏳ **Polish** — networking, a native filesystem, users & permissions, a
  package manager, and more.

This is a marathon, not a sprint. Progress happens phase by phase.

## Building & running

You will need: **Zig 0.16+**, **QEMU**, **GRUB** (`grub-mkrescue`),
**xorriso**, and **LLD** (`ld.lld`).

```sh
zig build          # compile the kernel
zig build iso      # build a bootable ISO (zig-out/nevara.iso)
zig build run      # build and boot it in QEMU
```

You can also boot `zig-out/nevara.iso` in VirtualBox, virt-manager, or on real
hardware. Use a BIOS or UEFI machine with a standard VGA/QXL/virtio display.

## Technical details

See the [deeper engineering notes](#technical-details-for-the-curious) below —
architecture, the boot path, the linker quirks, and per-subsystem design.

## License

MIT. See [`LICENSE`](LICENSE) (documentation: CC BY 4.0).

---

## Technical details (for the curious)

**Target:** x86_64, freestanding, SIMD disabled / soft-float in the kernel.

**Boot path.** GRUB loads the kernel as a Multiboot2 image and hands control
over in 32-bit protected mode. A small assembly trampoline builds identity page
tables (first 4 GiB, 2 MiB pages), enables PAE + long mode + paging, loads a
64-bit GDT, and jumps into the Zig entry point.

**Build system.** A single `build.zig` drives everything. The kernel is
compiled to one object with Zig and linked by **standalone `ld.lld`** with a
custom linker script — because on this Zig 0.16 toolchain the self-hosted ELF
linker ignores custom `SECTIONS` (which would push the Multiboot2 header out of
GRUB's 32 KiB search window) and the `-flld` path crashes. The kernel also
provides its own `memcpy`/`memmove`/`memset`/`memcmp` since compiler-rt is not
linked in.

**Display.** The kernel requests a linear RGB framebuffer (1024×768×32) via the
Multiboot2 header and renders text with a scaled public-domain 8×8 bitmap font.
All output is mirrored to the serial port (COM1) for debugging.

**Memory management.**

- *Physical (PMM):* a bitmap frame allocator built from the Multiboot2 memory
  map; 4 KiB frames; reserves low memory, the kernel image, the bitmap, and the
  boot info.
- *Virtual (VMM):* 4-level paging; maps/unmaps 4 KiB pages, allocating
  intermediate tables from the PMM; address translation honors 2 MiB huge pages.
- *Heap:* a first-fit free-list allocator exposed as `std.mem.Allocator`, backed
  by on-demand page mappings; supports splitting, coalescing, and arbitrary
  alignment.

**Processes & scheduling.** Kernel threads each own a heap-allocated stack;
`context_switch` (assembly) saves the callee-saved registers and RFLAGS, so the
interrupt flag is per-thread and new threads start preemptible. The 8259 PIC is
remapped to vectors 0x20-0x2F and the PIT fires IRQ0 at 100 Hz; the timer
handler acknowledges the interrupt and round-robins to the next ready thread.
Cooperative `yield()` uses the same switch primitive.

**Source layout.**

```
build.zig            build, ISO, and QEMU run steps
boot/grub/           GRUB configuration
kernel/
  main.zig           kernel entry point
  font.zig           bitmap font (public domain)
  arch/x86_64/       boot trampoline, GDT/IDT, serial, framebuffer, console
  mm/                pmm, vmm, heap
  proc/              scheduler and kernel threads
  lib/c.zig          freestanding mem builtins
```
