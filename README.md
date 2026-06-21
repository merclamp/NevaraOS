# Nevara OS

> ⚠️ **Status: early development.** Nevara OS is a hobby operating system being
> built from scratch. It is **not usable as a daily system yet** — right now it
> boots, sets up the CPU, manages memory, and drops into an interactive shell
> driven by a PS/2 keyboard. Expect breaking changes, rewrites, and rough edges.

English · [Русский](README.ru.md)

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
- Boots on standard PCs via GRUB from a **single ISO image** that contains
  both the kernel and the root filesystem (`rootfs.ext4` embedded inside).
  No separate disk images needed to distribute or boot.
- Its own framebuffer terminal (1024×768) with ANSI colours, a block cursor, and
  Linux-style line editing — arrow keys, history, and the usual Ctrl shortcuts.
- A clean, modular kernel where every piece is meant to be understandable.
- Runs real ring-3 programs from a built-in ELF loader, including an init
  system (**ZInit**), a multi-call coreutils binary (**NevBox**), and its own
  C library (**ZLibc**) — all written in Zig, no external libc. ZLibc now
  covers `ctype.h`, `string.h` (20 functions), `stdlib.h` (13 functions),
  and `stdio.h` with a full `printf`/`sprintf`/`snprintf`/`sscanf`/`scanf`.
- An interactive shell (**nsh**) with pipelines (`cmd1 | cmd2`), I/O redirection
  (`> file`, `>> file`, `< file`), background jobs (`cmd &`), shell variables
  (`FOO=bar`, `$FOO`), and a `cd` builtin. The prompt shows the current user
  and working directory (`root@nevara:/#` in red, `user@nevara:/home/user$` in
  green).
- **ext4 as the primary read-write filesystem** — the root filesystem is a real
  ext4 volume mounted at `/`: files and directories created in the shell persist
  across reboots. The driver supports extent trees (depth-0 and depth-1 for
  files beyond ~4 MiB), block/inode allocation, directory entry management,
  inode timestamps, and file-permission bits with `chmod` — no journal, no
  checksums (matching the mke2fs flags used to build the image).
- **50+ NevBox applets**: `echo` `cat` `ls` `wc` `grep` `head` `tail` `cp`
  `mv` `rm` `touch` `mkfile` `mkdir` `sort` `uniq` `cut` `tr` `rev` `pwd`
  `yes` `basename` `dirname` `seq` `tee` `true` `false` `sleep` `uptime`
  `uname` `nevfetch` `chmod` `find` `stat` `strings` `fold` `comm` `printf`
  `which` `xargs` `ln` `env` `dd` `od` `nl` `du`
  `whoami` `id` `su` `useradd` `userdel` `passwd`
  `ping` `ifconfig` — all in one multi-call binary, no libc.

## Current status

Twelve foundational stages are done and verified in QEMU:

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
  background jobs via a trailing `&`.
- ✅ **ext4 read-write root filesystem** — the kernel mounts a real ext4 volume
  as `/` on ATA primary master. Full read-write: files and directories created
  from the shell (`mkfile`, `mkdir`) are persisted to the disk image across
  reboots. The driver handles extent trees (depth-0 in-inode and depth-1 index
  nodes for files beyond ~4 MiB), block and inode bitmaps, GDT/superblock
  free-count tracking, directory entry creation and removal, sparse-block holes,
  `rename`, inode timestamps (atime/mtime/ctime), and file permission bits
  (`chmod`). The ISO ships a pre-populated rootfs image with `/bin`, `/etc`,
  `/tmp`, `/mnt` and all userland binaries.
- ✅ **Single-ISO distribution** — `zig build iso` produces one self-contained
  `nevara.iso` with the kernel at `/boot/kernel` and the ext4 rootfs at
  `/boot/rootfs.ext4`. Booting only requires this ISO plus the rootfs image as
  a separate ATA drive for QEMU (extracted from the ISO automatically by
  `zig build run`). `zig-out/bin/kernel` is not needed to boot.
- ✅ **Pipes & I/O redirection** — anonymous pipes with correct reference
  counting (`pipe`/`dup2`/close-on-exec); **nsh** parses `|`, `>`, `>>`, `<`
  and runs multi-stage pipelines.
- ✅ **Working directory & relative paths** — every process tracks its own cwd
  (`chdir`/`getcwd` syscalls, Linux numbers 80/79). All path-taking syscalls
  resolve relative paths against the cwd with full `.`/`..` normalisation.
- ✅ **Rich userland tooling** — **NevBox** provides 50+ applets covering text
  processing, file management, system info, and binary inspection. Shell
  variables work in **nsh**. The PIT exports a 100 Hz `jiffies` counter so
  `uptime` and `nevfetch` show real elapsed time.
- ✅ **Users & permissions** — POSIX credentials (uid/gid/euid/egid) on every
  process, inherited across `fork`/`execve`; a kernel user database (max 32
  users, pre-seeded with root) persisted to `/etc/passwd`; `/home/` directory
  for user home dirs; `useradd`/`userdel`/`su`/`whoami`/`id` applets;
  `getuid`/`setuid`/`getgid`/`setgid` and custom `useradd`/`userdel`/
  `getpwnam` syscalls; **nsh** prompt shows `user@nevara:path` with colour.
- ⚙️  **Networking (implemented, pending end-to-end test)** — PCI scanner,
  RTL8139 driver (IRQ-driven RX, 32-bit DMA via `pmm.allocLow32`),
  Ethernet/ARP/IPv4/ICMP/UDP stack; static IP 10.0.2.15/24, GW 10.0.2.2
  (QEMU SLIRP). `ping` and `ifconfig` NevBox applets; `net_ping`/
  `net_send`/`net_recv`/`net_info` syscalls. `zig build run` adds
  `-netdev user -device rtl8139` to QEMU automatically.

## Roadmap

What still needs to be built (roughly in order):

- ✅ **ext4 write hardening** — large files (depth-1 extent index nodes for
  files beyond ~4 MiB), inode timestamps (atime/mtime/ctime from PIT jiffies),
  and file-permission bits with `chmod` (syscall 90, NevBox applet).
- ✅ **Richer ZLibc** — `ctype.h` (12 functions), `string.h` (20 functions),
  `stdlib.h` (13 functions), `stdio.h` with full `printf`/`sprintf`/`snprintf`/
  `sscanf`/`scanf`, `calloc`/`realloc`, `strtol`/`strtoul`, `strtok`, and more.
- ✅ **More NevBox applets** — `find`, `stat`, `strings`, `fold`, `comm`,
  `printf`, `which`, `xargs`, `ln`, `env`, `dd`, `od`, `nl`, `du` (15 new
  applets; total now 50+ with user-management applets).
- ✅ **Users & permissions** — kernel uid/gid credentials, user DB, `/home`,
  `useradd`/`userdel`/`su`/`whoami`/`id` NevBox applets, POSIX credential
  syscalls, coloured `user@nevara` prompt in **nsh**.
- ⏳ **Networking end-to-end test** — verify `ping 10.0.2.2` replies,
  ARP handshake, and UDP round-trip from inside the running OS.
- ⏳ **Polish** — package manager, TCP, and more.

This is a marathon, not a sprint. Progress happens phase by phase.

## Building & running

You will need: **Zig 0.16+**, **QEMU**, **GRUB** (`grub-mkrescue`),
**xorriso**, **LLD** (`ld.lld`), and **e2fsprogs** (`mke2fs`).

```sh
zig build          # compile the kernel (zig-out/bin/kernel)
zig build iso      # build a bootable ISO (zig-out/nevara.iso)
                   # also produces zig-out/rootfs.ext4
zig build run      # build, populate rootfs, and boot in QEMU
```

**To boot the ISO** you also need `zig-out/rootfs.ext4` as a separate ATA
disk. `zig build run` handles this automatically by copying the rootfs image
from the build cache. `zig-out/bin/kernel` is **not** required at runtime —
the kernel is embedded inside the ISO at `/boot/kernel`.

You can boot `zig-out/nevara.iso` + `zig-out/rootfs.ext4` in VirtualBox,
virt-manager, or on real hardware. Use a BIOS or UEFI machine with a standard
VGA/QXL/virtio display.

`zig build run` launches QEMU with `-serial stdio`, so the boot log and shell
output are mirrored to your terminal, while the framebuffer console is shown in
the QEMU window. **Type into the QEMU window** to interact with `nsh` — input
is the emulated PS/2 keyboard, not the serial port. Before the shell appears,
the kernel prints a short run of self-tests (PMM, VMM, heap) as a boot-time
sanity check.

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
linked in. The `zig build iso` step:
1. Compiles all userspace ELF binaries.
2. Assembles a rootfs staging directory with `/bin`, `/etc`, `/tmp`, `/mnt`.
3. Runs `mke2fs` to produce `rootfs.ext4` (no journal, no checksums, 1 KiB blocks).
4. Packs kernel + rootfs + GRUB config into a single ISO via `grub-mkrescue`.

**Display.** The kernel requests a linear RGB framebuffer (1024×768×32) via the
Multiboot2 header and drives it as a small ANSI/VT100 terminal: a colour cell
grid rendered with a public-domain 8×8 bitmap font, a block cursor, and a CSI
escape parser (cursor movement, line/screen erase, and SGR 16-colour
attributes). All output is mirrored to the serial port (COM1) for debugging.

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
descriptor table, a program break, a **current working directory** (256-byte
kernel buffer, inherited across `fork`/`execve`), and a kernel thread the
scheduler time-slices. Each thread keeps its own kernel stack; the scheduler
re-points TSS.rsp0 and the SYSCALL stack on every switch so concurrent ring-3
processes trap onto their own stacks, and it reloads CR3 so preemption lands in
the right address space. `context_switch` (assembly) saves the callee-saved
registers and RFLAGS, so the interrupt flag is per-thread. The 8259 PIC is
remapped to vectors 0x20-0x2F and the PIT fires IRQ0 at 100 Hz to drive
round-robin preemption; each IRQ0 also increments `pit.jiffies` for uptime.

**Filesystem & system calls.** The VFS layer holds an in-memory (tmpfs-style)
tree for `/dev` and other kernel-created nodes. At boot, the kernel mounts an
ext4 volume (ATA primary master) as the VFS root, populating the tree from the
on-disk directory entries. All `create`/`unlink`/`rename`/`writeAt`/`rmdir`
operations on ext4-backed nodes are propagated to disk in real time.

The **ext4 driver** (`ext4.zig`) supports:
- *Read:* superblock, GDT (cached in RAM), inodes, extent trees (depth 0–2),
  linear directory entries, sparse holes.
- *Write:* block/inode allocation from bitmaps with GDT and superblock
  free-count updates; extent trees up to depth-1 (in-inode index node → leaf
  blocks on disk, supports files well beyond 100 MiB at 1 KiB block size, with
  run-length merging); full file overwrite (`writeFile`); directory entry
  insertion (slack-space reuse + new block allocation) and removal; `createFile`,
  `createDir` (with `.` and `..`), `unlinkFile` (free blocks + free inode),
  `renameEntry`; inode timestamps on create/write/chmod; `chmod`/`getMode`.

On top sits a per-process file-descriptor table and a dispatcher keyed by the
Linux x86_64 syscall numbers (read, write, open, close, lseek, getpid, brk,
fork, execve, exit, wait4, mkdir, pipe, dup2, getdents64, chdir=80, getcwd=79,
spawn=1000, uptime=1001, unlink=87, rename=82, sleep=1002, rmdir=84, chmod=90,
getuid=102, getgid=104, geteuid=107, getegid=108, setuid=105, setgid=106,
useradd=1003, userdel=1004, getpwnam=1005), returning
negative errno on failure. All path-taking syscalls resolve relative paths
against the current process's cwd via an internal `toAbsPath` helper.

**Input & TTY.** A PS/2 keyboard driver (`kbd.zig`) is wired to IRQ1: it reads
scancodes from port 0x60, tracks Shift/Ctrl/Caps Lock, decodes the 0xE0 extended
set (arrows, Home/End, Delete, ...), and pushes a byte stream into a 256-byte
ring. The line discipline (`tty.zig`) implements canonical-mode editing: an
in-line cursor with insert/delete, word/line kills, and command history, all
echoed through the escape sequences the framebuffer terminal understands.

**Userspace & multitasking.** Ring 3 is entered via `iretq`; user programs trap
in with the `syscall` instruction, which saves a full trap frame and returns the
same way. An ELF64 loader maps static executables into per-process address
spaces. The process syscalls are real: `fork` deep-copies the caller's user
pages, `execve` swaps in a new image, `wait4`/`waitpid` reap a zombie child,
and `exit` turns a process into a zombie until its parent reaps it. Userland is
built on two Zig runtimes — **nstd** (native, libc-free) and **ZLibc** (a C
library written in Zig, compiled by `zig cc`): `ctype.h` (12 classification and
conversion functions), `string.h` (20 functions: strlen/strcpy/strcat/strcmp/
strchr/strstr/strdup/strtok/memmove/memcmp/memchr and more), `stdlib.h`
(malloc/calloc/realloc/free/atoi/atol/strtol/strtoul/abs/abort …), `stdio.h`
(printf/fprintf/sprintf/snprintf with full flags+width+precision, sscanf/scanf,
puts/getchar/fputs/fflush …); on top sit **ZInit** (PID 1), **nsh** (the
interactive shell), and **NevBox** (50+ applets).

**Source layout.**

```
build.zig            build, ISO, and QEMU run steps
boot/grub/           GRUB configuration
kernel/
  main.zig           kernel entry point
  tty.zig            TTY line discipline (in-line editing + history)
  font.zig           bitmap font (public domain)
  arch/x86_64/       boot trampoline, GDT/IDT, serial, framebuffer terminal,
                     PS/2 keyboard, ATA PIO driver, PIT (jiffies counter)
  mm/                pmm, vmm, heap
  proc/              scheduler, kernel threads, and the process model (+ cwd)
  fs/                VFS (tmpfs + /dev), ext4 read-write driver
  syscall/           file descriptors, path resolution, and the syscall dispatcher
  exec/elf.zig       ELF64 loader
  lib/c.zig          freestanding mem builtins
user/
  nstd/              native libc-free Zig runtime
  init.zig, zinit/   first program and the init system (PID 1, getty-style)
  nevbox/            multi-call coreutils utility (30+ applets)
  nsh/               the interactive shell (pipelines, redirection, variables)
zlibc/               our own C library (Zig) + headers
```
