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
- Its own framebuffer terminal (800×600) with ANSI colours, a block cursor, and
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
  `uname` `nevfetch` `chmod` `chown` `find` `stat` `strings` `fold` `comm` `printf`
  `which` `xargs` `ln` `env` `dd` `od` `nl` `du`
  `whoami` `id` `su` `useradd` `userdel` `passwd`
  `ping` `ifconfig` `zinit-ctl` `reboot` `poweroff` `clear` `kill` `sigtest` `dactest`
  — all in one multi-call binary, no libc.

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
- ✅ **Networking (end-to-end verified)** — PCI scanner, RTL8139 driver
  (IRQ-driven RX, 32-bit DMA via `pmm.allocLow32`), Ethernet/ARP/IPv4/ICMP/UDP
  stack; static IP 10.0.2.15/24, GW 10.0.2.2 (QEMU SLIRP). `ping` and
  `ifconfig` NevBox applets; `net_ping`/`net_send`/`net_recv`/`net_info`
  syscalls. End-to-end verified: `ping -c 3 10.0.2.2` → 3/3 received, ARP
  cache populated, IRQ11 routing confirmed. `zig build run` adds
  `-netdev user -device rtl8139` to QEMU automatically.


## Roadmap

### Phase I — Foundation ✅ Complete

Everything below has been built and verified in QEMU:

| Area | What was done |
|---|---|
| Boot & memory | GRUB/Multiboot2 → 64-bit, PMM (bitmap), VMM (4-level paging), heap (first-fit) |
| Processes | fork/execve/wait4/exit, preemptive round-robin scheduler (100 Hz PIT) |
| Syscalls | 35+ Linux-compatible syscall numbers, full errno, toAbsPath resolver |
| Filesystem | ext4 read-write (depth-0/1 extents, timestamps, chmod), VFS tmpfs layer |
| Userspace | nstd + ZLibc (ctype/string/stdlib/stdio), ZInit PID 1, nsh shell |
| Shell | Pipelines, I/O redirect, background jobs, shell variables, history |
| NevBox | 50+ applets (echo cat ls wc grep find dd ping ifconfig whoami …) |
| Users | uid/gid/euid/egid per-process, user DB → /etc/passwd, useradd/userdel/su |
| Networking | PCI scan, RTL8139 + DMA fix, ARP/IPv4/ICMP/UDP, ping 3/3 e2e ✓ |
| TCP | RFC 793 state machine, 16 sockets, connect/listen/accept/send/recv, retransmit |
| TTY | Canonical + raw mode (SYS_tty_mode=1020), ANSI/VT100 terminal |

---

### Phase II — Stabilisation & System Services

Phase II picks up immediately where Phase I left off.

#### II-A · Phase I loose ends ✅ Complete

- ✅ **Networking end-to-end test** — `ping -c 3 10.0.2.2` → 3/3 received from
  QEMU SLIRP; ARP cache populated; IRQ11 confirmed.
- ✅ **TCP stack** — RFC 793 state machine (16 sockets); `connect`/`listen`/
  `accept`/`send`/`recv`/`close` syscalls (1014–1022); retransmit timer;
  TIME_WAIT; nstd wrappers. All Phase I networking items closed.

#### II-B · ZLibc — complete POSIX coverage

ZLibc currently covers ctype / string / stdlib / stdio.  The next layer:

- ⏳ **`time.h`** — `time()`, `clock()`, `difftime()`, `gmtime()`/`localtime()`
  (backed by `pit.jiffies`; no RTC yet, boot epoch = 0).
- ⏳ **`errno.h` + thread-local errno** — a per-process `errno` cell written by
  every failing syscall wrapper; `perror()`, `strerror()`.
- ⏳ **`signal.h` (POSIX subset)** — `signal()`, `kill()`, `raise()`,
  `SIGINT`/`SIGTERM`/`SIGKILL`/`SIGSEGV`; kernel signal delivery on syscall
  return (no real-time signals in this phase).
- ⏳ **`setjmp.h`** — `setjmp`/`longjmp` in Zig inline asm.
- ⏳ **`math.h` (integer-only fast path)** — `abs`, `labs`, `llabs`, `pow`
  (integer exponent), `sqrt` (Newton–Raphson); float functions remain stubs
  until compiler-rt is available.
- ⏳ **`unistd.h` additions** — `getenv` (reads synthetic env block), `access`,
  `dup`, `isatty`, `symlink`, `readlink`.

#### II-C · Nano port

Port **GNU Nano** to Nevara OS as the primary interactive text editor.
Nano is written in C and uses only standard POSIX / curses interfaces,
making it a realistic porting target once ZLibc is sufficiently complete.

- ⏳ **Prerequisite: ZLibc II-B** — Nano requires `termios`, `ioctl` (window
  size), `signal`, `setjmp`, `time`, `errno`, `isatty`; complete II-B first.
- ⏳ **termios / ioctl stubs** — implement `tcgetattr`/`tcsetattr`/`cfmakeraw`
  backed by `SYS_tty_mode`; `TIOCGWINSZ` returning fixed 100×75 (800×600 / 8).
- ⏳ **curses shim** — a minimal `ncurses`-compatible layer (`initscr`, `endwin`,
  `move`, `addch`, `addstr`, `clrtoeol`, `refresh`, `getch`, `keypad`,
  colour pairs) rendered via VT100 sequences to the kernel console.
- ⏳ **Build integration** — cross-compile Nano with `zig cc` against ZLibc
  headers; embed the ELF in rootfs as `/bin/nano`; wire into `zig build iso`.
- ⏳ **Smoke test** — `nano /etc/hostname` opens, edits, and saves; Ctrl-X
  exits; arrow keys, PgUp/PgDn, Ctrl-K/U work correctly.

#### II-D · ZInit — real PID 1 ✅ Complete

ZInit is now a real supervisor instead of a getty exec-loop:

- ✅ **Service table** — a static array of service descriptors (name, path,
  args, restart policy) parsed from `/etc/zinit.conf`. Format is
  `<name> <respawn|once|wait> <path> [args...]`, with a `target single|multi`
  directive; start order in the file *is* the dependency order. A built-in
  default (`shell respawn /bin/nsh`) is used if the config is missing.
- ✅ **Supervision loop** — services are spawned with `fork`/`execve`, reaped
  with non-blocking `wait4(WNOHANG)`, and `respawn` services are restarted with
  **exponential back-off** (1→2→4…→30 s, reset after 60 s of uptime). `wait`
  services run to completion before later services start; `once` services never
  restart. Verified in QEMU: a crashing service restarts at 1 s, 2 s, 4 s, … .
- ✅ **Runlevels / targets** — `single` (maintenance shell only), `multi`
  (all services), and `reboot` / `poweroff` via a new kernel **`SYS_reboot`**
  syscall (QEMU ACPI port `0x604`/`0xB004` for power-off; `0x64`/`0xCF9` reset
  for reboot).
- ✅ **`zinit-ctl` applet** — `status` / `list`, `start <svc>`, `stop <svc>`,
  `restart <svc>`, `single`, `multi`, `reboot`, `poweroff`. Talks to PID 1
  through a polled command file (`/var/run/zinit.ctl`); ZInit publishes a live
  snapshot to `/var/run/zinit.status`. Plus standalone `reboot` / `poweroff`
  applets that call `SYS_reboot` directly. `stop`/`restart` of a running
  service send **SIGTERM** (II-E signals) and the service is reaped on the next
  supervision pass.
- ✅ **Syslog** — lifecycle events are timestamped (from `pit.jiffies`) and
  appended to `/var/log/syslog`, **rotated to `syslog.0` at 1 MiB**, and
  mirrored to the console.

#### II-E · Kernel hardening

- ✅ **Signals kernel-side** — `SYS_kill=62`, `SYS_signal=48`, `SYS_sigreturn`,
  with a per-process pending bitmask and disposition table (`SIG_DFL`/`SIG_IGN`/
  handler). Delivered on the syscall-return path: a caught signal runs a real
  **user handler** on a frame built on the user stack and returns through a
  `sigreturn` trampoline (System-V one-shot semantics). Default actions
  terminate (SIGINT/TERM/SEGV/KILL…; SIGKILL uncatchable). Blocking waits (TTY
  read, `wait4`, `sleep`) are signal-interruptible, so `kill` reaches a blocked
  process; a ring-3 CPU exception is turned into **SIGSEGV** (the kernel no
  longer halts on a bad user pointer). Ctrl-C raises SIGINT (the shell ignores
  it). `kill` NevBox applet + `sigtest` self-test; nstd `kill`/`signal`/`raise`.
  Verified in QEMU: handler round-trip, default-terminate, and SIGSEGV-from-fault
  all produce the expected status words.
- ✅ **`/proc` virtual filesystem** — a synthetic in-RAM tree whose files carry
  no stored data: each read runs a generator over live kernel state. Globals:
  `version`, `uptime`, `meminfo` (from the page allocator), `cpuinfo` (vendor +
  brand via `CPUID`), `stat`, `loadavg`, `filesystems`, `mounts`, `cmdline`, and
  `sys/kernel/{hostname,ostype,osrelease,version}`. **One directory per live
  process** is enumerated on demand through a VFS synthetic-directory hook, so
  `ls /proc` lists real PIDs and `cat /proc/<pid>/{status,stat,cmdline}` reads
  the live process table; `/proc/self` resolves to the reading process. Verified
  in QEMU.
- ✅ **`/sys` stubs** — `/sys/kernel/{hostname,ostype,osrelease}` plus the
  conventional skeleton (`devices`, `class`, `block`, `bus`, `firmware`,
  `module`) for tools that probe the tree.
- ✅ **File-permission enforcement (DAC)** — every VFS node carries owner
  uid/gid + permission bits, loaded from the ext4 inode and written back on
  change (this also fixed a latent bug where `i_ctime` was written over `i_gid`).
  `open()` enforces classic Unix rwx by owner/group/other class (root bypasses
  read/write; execute still needs an x bit); `execve`/`spawn` require execute;
  new files/dirs are owned by their creator. `SYS_chmod`/`SYS_fchmod=91` are
  owner-or-root, `SYS_chown=92` is root-only; a compact `stat` syscall exposes
  mode/uid/gid (NevBox `stat`, `chmod`, **`chown`**). Verified by the `dactest`
  applet: 8/8 checks (root bypass, other-class deny, group/owner grants, write
  protection, chmod-EPERM, exec-needs-x) all pass in QEMU.
- ⏳ **Demand paging / CoW fork** — copy-on-write page fault handler; `fork()`
  no longer deep-copies all pages; only modified pages are duplicated.
- ⏳ **mmap stub** — `SYS_mmap=9` for anonymous mappings (needed by musl and
  many programs); backed by VMM page allocation.

#### II-F · Network server stack

With TCP in place, build the first services:

- ⏳ **DHCP client** — DHCPDISCOVER/DHCPOFFER/DHCPREQUEST on boot; configure
  IP, netmask, GW, DNS dynamically (QEMU SLIRP responds).
- ⏳ **DNS resolver** — simple iterative resolver; cache up to 64 RRs; expose
  as `getaddrinfo()` stub in ZLibc.
- ⏳ **HTTP client (`httpget`)** — NevBox applet: `httpget <url>` → TCP connect
  → raw HTTP/1.0 GET → print body; no TLS in this phase.
- ⏳ **Minimal HTTP server (`httpd`)** — serve static files from `/var/www/html`
  over TCP port 80; single-threaded (fork per request); useful for demos.
- ⏳ **SSH-lite** — a tiny custom remote shell protocol over TCP (not full SSH);
  authenticate with the user DB; run a shell on the connection.

#### II-G · Package manager (`npkg`)

- ⏳ **Package format** — a `.npkg` tar.gz with a `MANIFEST` (name, version,
  files, deps); built from the same `build.zig` pipeline.
- ⏳ **`npkg install / remove / list / update`** — NevBox applet or standalone
  binary; downloads packages via `httpget`, verifies SHA256, extracts to `/`.
- ⏳ **Package index** — a static `packages.idx` file served by the HTTP server;
  no dynamic registry in this phase.

#### II-H · Developer tools

- ⏳ **`nasm`-lite assembler** — a tiny x86_64 assembler for educational use;
  subset of NASM syntax; outputs flat binaries or ELF objects.
- ⏳ **`nld` linker** — minimal ELF static linker sufficient to link
  nstd-based programs from object files.
- ⏳ **`ncc` Zig compiler front-end** — thin wrapper around `zig cc` that sets
  the correct freestanding target and linker script.

#### II-I · Desktop environment (final milestone)

After the server stack is stable and tested, bring up a graphical environment:

- ⏳ **Framebuffer compositor** — a minimal window manager that blits rectangular
  windows onto the 800×600 framebuffer; double-buffered to avoid tearing.
- ⏳ **PS/2 mouse driver** — extend `kbd.zig` to handle IRQ12 (PS/2 auxiliary
  port); decode X/Y delta + buttons; route to the compositor.
- ⏳ **Window protocol** — a simple message queue (shared-memory ring or pipe)
  between apps and the compositor: `WM_CREATE_WINDOW`, `WM_DRAW_RECT`,
  `WM_KEY_EVENT`, `WM_MOUSE_EVENT`.
- ⏳ **Terminal emulator** — a graphical window that embeds nsh; renders text
  with the existing 8×8 bitmap font; supports ANSI/VT100 codes.
- ⏳ **File manager** — a two-pane file browser (à la Midnight Commander) drawn
  in the framebuffer; uses `getdents64` for directory listing.
- ⏳ **Application launcher** — a status bar with a clock (from `pit.jiffies`),
  network indicator, and a button that opens an app list.
---

This is a marathon, not a sprint. Progress happens phase by phase.

## Building & running

You will need: **Zig 0.16+**, **QEMU**, **GRUB** (`grub-mkrescue`),
**xorriso**, **LLD** (`ld.lld`), and **e2fsprogs** (`mke2fs`).

```sh

zig build          # compile the kernel (zig-out/bin/kernel)
zig build iso      # build bootable ISO (zig-out/nevara.iso + zig-out/rootfs.ext4)
zig build run      # build, populate rootfs, and boot in QEMU
```

**To boot the ISO** you also need `zig-out/rootfs.ext4` as a separate ATA
disk. Both `zig build iso` and `zig build run` produce it automatically —
`zig build iso` copies the rootfs image to `zig-out/rootfs.ext4` alongside
the ISO. `zig-out/bin/kernel` is **not** required at runtime — the kernel is
embedded inside the ISO at `/boot/kernel`.
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
5. Copies `rootfs.ext4` to `zig-out/` alongside the ISO for convenient QEMU use.

**Display.** The kernel requests a linear RGB framebuffer (800×600×32) via the
Multiboot2 header and drives it as a small ANSI/VT100 terminal: a colour cell
grid rendered with a public-domain 8×8 bitmap font scaled 2× to 16×16 px (50 columns
× 37 rows at 800×600), a block cursor, and a CSI escape parser (cursor movement,
line/screen erase, and SGR 16-colour attributes). All output is mirrored to the
serial port (COM1) for debugging.

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
  fs/                VFS (tmpfs + /dev), ext4 read-write driver, procfs (/proc + /sys)
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
