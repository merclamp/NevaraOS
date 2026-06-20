# Nevara OS

> ⚠️ **Status: early development.** Nevara OS is a hobby operating system being
> built from scratch. It is **not usable as a daily system yet** — right now it
> boots, sets up the CPU, manages memory, and drops into an interactive shell
> driven by a PS/2 keyboard. Expect breaking changes, rewrites, and rough edges.

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
- Its own framebuffer terminal (1024×768) with ANSI colours, a block cursor, and
  Linux-style line editing — arrow keys, history, and the usual Ctrl shortcuts.
- A clean, modular kernel where every piece is meant to be understandable.
- Runs real ring-3 programs from a built-in ELF loader, including an init
  system (**ZInit**), a multi-call coreutils binary (**NevBox**), and its own
  C library (**ZLibc**) — all written in Zig, no external libc.
- An interactive shell (**nsh**) with pipelines (`cmd1 | cmd2`), I/O redirection
  (`> file`, `>> file`, `< file`), and background jobs (`cmd &`).

- Reads and writes a real disk: **FAT16** at `/mnt` (subdirectories, mkfile,
  mkdir) interoperable with fsck.fat / mtools; **ext4** at `/ext` (read-only).

## Current status

Ten foundational stages are done and verified in QEMU:

- ✅ **Boot & bring-up** — boots through GRUB into 64-bit mode, sets up the CPU
  (segments, interrupt/exception handling), reads the machine's memory layout,
  and renders output to the screen.
- ✅ **Memory management** — tracks all physical RAM, manages virtual memory
  (page tables), and provides a growing kernel heap.
- ✅ **Processes & scheduling** — kernel threads with context switching and a
  preemptive, timer-driven round-robin scheduler.
- ✅ **Filesystem & system calls** — an in-memory filesystem (files, directories,
  devices) and a Linux-compatible system call layer.
- ✅ **Userspace & init** — ring 3 with a `syscall` entry, an ELF loader,
  isolated per-process address spaces, the ZLibc/nstd runtimes, and **ZInit**
  (PID 1) launching **NevBox** applets and C programs.
- ✅ **Interactive shell & TTY** — a PS/2 keyboard driver (scancode set 1, with
  Shift, Ctrl, Caps Lock, and the 0xE0 extended keys) feeds a real line
  discipline: an in-line cursor with insert/delete (arrows, Home/End, Delete,
  backspace), word/line kills (Ctrl-A/E/U/K/W/L), and command history (Up/Down).
  The framebuffer is an ANSI/VT100 terminal (16 colours, block cursor, cursor
  and erase escapes). **nsh** reads a line, parses argv, and spawns `/bin/<cmd>`;
  **ZInit** supervises it getty-style, respawning the shell whenever it exits.
- ✅ **Concurrent multitasking** — real `fork` / `execve` / `wait` / `exit`: every
  process gets its own address space and kernel thread, the timer round-robins
  between them, and **nsh** runs commands the Unix way (fork + exec + wait), with
  background jobs via a trailing `&`. The `demo` builtin forks two children whose
  output interleaves to show preemption.
- ✅ **Real disk storage (FAT16 + ext4)** — an ATA (IDE) PIO block driver feeds
  two filesystems. **FAT16** mounts at `/mnt`: full read/write with
  subdirectories, `mkfile`/`mkdir` from the shell, persistent across reboots,
  host-interoperable with `fsck.fat` / mtools. **ext4** mounts read-only at
  `/ext`: extent-based files, linear directories, and subdirectories — produced
  by `mke2fs` on the host, read transparently by the kernel.
- ✅ **Pipes & I/O redirection** — anonymous pipes with correct reference
  counting (`pipe`/`dup2`/close-on-exec); **nsh** parses `|`, `>`, `>>`, `<`
  and runs multi-stage pipelines: `echo hi | cat`, `ls | cat | cat`,
  `cat < file`, `echo text > file`.
## Roadmap

What still needs to be built (roughly in order):

- ⏳ **More userland** — more NevBox applets (wc, grep, head), a richer ZLibc.
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

`zig build run` launches QEMU with `-serial stdio`, so the boot log and shell
output are mirrored to your terminal, while the framebuffer console is shown in
the QEMU window. **Type into the QEMU window** to interact with `nsh` — input
is the emulated PS/2 keyboard, not the serial port. Before the shell appears,
the kernel prints a short run of self-tests (PMM, VMM, heap, scheduler, VFS,
syscalls) as a boot-time sanity check.

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
Multiboot2 header and drives it as a small ANSI/VT100 terminal: a colour cell
grid rendered with a public-domain 8×8 bitmap font (native size), a block
cursor, and a CSI escape parser (cursor movement, line/screen erase, and SGR
16-colour attributes). Console writes briefly disable interrupts so a timer
preemption can't corrupt the shared terminal state. All output is mirrored to
the serial port (COM1) for debugging.

**Memory management.**

- *Physical (PMM):* a bitmap frame allocator built from the Multiboot2 memory
  map; 4 KiB frames; reserves low memory, the kernel image, the bitmap, and the
  boot info.
- *Virtual (VMM):* 4-level paging; maps/unmaps 4 KiB pages, allocating
  intermediate tables from the PMM; address translation honors 2 MiB huge pages.
- *Heap:* a first-fit free-list allocator exposed as `std.mem.Allocator`, backed
  by on-demand page mappings; supports splitting, coalescing, and arbitrary
  alignment.

**Processes & scheduling.** Every process owns an address space, a file-
descriptor table, a program break, and a kernel thread the scheduler time-slices.
Each thread keeps its own kernel stack; the scheduler re-points TSS.rsp0 and the
SYSCALL stack on every switch so concurrent ring-3 processes trap onto their own
stacks, and it reloads CR3 so preemption lands in the right address space.
`context_switch` (assembly) saves the callee-saved registers and RFLAGS, so the
interrupt flag is per-thread. The 8259 PIC is remapped to vectors 0x20-0x2F and
the PIT fires IRQ0 at 100 Hz to drive round-robin preemption.

**Filesystem & system calls.** A virtual filesystem layer backs an in-memory
(tmpfs-style) tree of files, directories, and character devices (`/dev/null`,
is supported too: an ATA (IDE) PIO block driver (`ata.zig`) addresses two IDE
disks (master and slave). A FAT16 driver (`fat.zig`) mounts at `/mnt`: it parses
an existing volume's BPB or formats a fresh 16 MiB one, supports nested
subdirectories (cluster chains + dot/dotdot entries), reads/writes files lazily
through VFS nodes, and produces genuine FAT16 images that round-trip with host
tools. A read-only ext4 driver (`ext4.zig`) mounts at `/ext`: it reads the
superblock, block-group descriptors, inodes, and extent trees, and presents files
and subdirectories through the same VFS. On top sits a per-process
file-descriptor table and a dispatcher keyed by the Linux x86_64 syscall numbers
(read, write, open, close, lseek, getpid, brk, mkdir, getdents64, ...), returning
negative errno on failure.

**Input & TTY.** A PS/2 keyboard driver (`kbd.zig`) is wired to IRQ1: it reads
scancodes from port 0x60, tracks Shift/Ctrl/Caps Lock, decodes the 0xE0 extended
set (arrows, Home/End, Delete, ...), and pushes a byte stream — ASCII, control
codes, and VT100 escape sequences — into a 256-byte ring, exactly the way a
terminal feeds an application. The line discipline (`tty.zig`) drains it and
implements canonical-mode editing: an in-line cursor with insert/delete,
word/line kills, and command history, all echoed through the escape sequences the
framebuffer terminal understands. `/dev/console`'s read side returns one
completed line. The keyboard IRQ is unmasked just before ZInit starts.

**Userspace & multitasking.** Ring 3 is entered via `iretq`; user programs trap
in with the `syscall` instruction, which saves a full trap frame and returns the
same way (so fork can resume a child from a copied frame). An ELF64 loader maps
static executables into **per-process address spaces** (each its own PML4 sharing
the kernel half), so every program links at the same fixed high base without
colliding. The process syscalls are real: `fork` deep-copies the caller's user
pages, `execve` swaps in a new image, `wait4`/`waitpid` reap a zombie child (with
WNOHANG), and `exit` turns a process into a zombie until its parent reaps it.
Userland is built on two Zig runtimes — **nstd** (native, libc-free) and
**ZLibc** (a small C library compiled by `zig cc`); on top sit **ZInit** (PID 1,
a getty-style supervisor that respawns the shell), **nsh** (the interactive REPL,
which runs commands as fork + execve + wait and supports `&` background jobs), and
**NevBox** (a multi-call coreutils binary installed under `echo`/`cat`/`ls`).

**Source layout.**

```
build.zig            build, ISO, and QEMU run steps
boot/grub/           GRUB configuration
kernel/
  main.zig           kernel entry point
  tty.zig            TTY line discipline (in-line editing + history)
  font.zig           bitmap font (public domain)
  arch/x86_64/       boot trampoline, GDT/IDT, serial, framebuffer terminal, PS/2 keyboard, ATA
  mm/                pmm, vmm, heap
  proc/              scheduler, kernel threads, and the process model
  fs/                VFS (in-memory tmpfs + devices), FAT16, and ext4 drivers
  syscall/           file descriptors and the syscall dispatcher
  exec/elf.zig       ELF64 loader
  lib/c.zig          freestanding mem builtins
user/
  nstd/              native libc-free Zig runtime
  init.zig, zinit/    first program and the init system (PID 1, getty-style)
  nevbox/            multi-call coreutils utility (echo/cat/ls)
  nsh/               the interactive shell (REPL)
zlibc/               our own C library (Zig) + headers
```
