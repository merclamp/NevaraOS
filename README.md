# Nevara OS

> ⚠️ **Status: early development.** Nevara OS is a hobby operating system being
> built from scratch. It is **not** usable as a daily system yet — right now it
> boots, sets up the CPU, manages memory, and prints to the screen. Expect
> breaking changes, rewrites, and rough edges.

🇬🇧 English · [🇷🇺 Русский](#nevara-os-ру)

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

## Roadmap

What still needs to be built (roughly in order):

- ⏳ **Processes & scheduling** — tasks, context switching, a scheduler.
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

See [docs below](#technical-details-en) for the deeper engineering notes —
architecture, the boot path, the linker quirks, and per-subsystem design.

## License

MIT. See [`LICENSE`](LICENSE) (documentation: CC BY 4.0).

---

<a name="technical-details-en"></a>

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

**Source layout.**

```
build.zig            build, ISO, and QEMU run steps
boot/grub/           GRUB configuration
kernel/
  main.zig           kernel entry point
  font.zig           bitmap font (public domain)
  arch/x86_64/       boot trampoline, GDT/IDT, serial, framebuffer, console
  mm/                pmm, vmm, heap
  lib/c.zig          freestanding mem builtins
```

================================================================================

<a name="nevara-os-ру"></a>

# Nevara OS (RU)

> ⚠️ **Статус: ранняя разработка.** Nevara OS — любительская операционная
> система, которая пишется с нуля. Пользоваться ею как повседневной системой
> **пока нельзя** — сейчас она загружается, настраивает процессор, управляет
> памятью и выводит текст на экран. Возможны несовместимые изменения,
> переписывания и шероховатости.

[🇬🇧 English](#nevara-os) · 🇷🇺 Русский

---

Nevara OS — современная операционная система на языке
[Zig](https://ziglang.org). Это учебный проект и долгосрочная попытка собрать
свободную, независимую ОС — от момента передачи управления загрузчиком до
полноценного пользовательского окружения.

Название **Nevara** происходит от реки Невы в Санкт-Петербурге — родном городе
автора.

## Философия

Nevara OS построена на идее **по-настоящему свободного ПО** — свободы без
условий.

- **Свобода использовать** — запускайте для любых целей, без ограничений.
- **Свобода изучать** — открыта каждая строка исходного кода.
- **Свобода изменять** — форк это право, а не нарушение.
- **Свобода распространять** — делитесь оригиналом или своей версией.

И несколько обещаний, которые из этого следуют:

- **Никакой телеметрии.** Система не собирает данные о вас.
- **Никаких бэкдоров.** Весь код можно проверить.
- **Никаких проприетарных блобов.** Ничего без исходников.
- **Воспроизводимость.** Одинаковый исходник даёт одинаковый бинарь.

Лицензия — **MIT**. Выбрана для того, чтобы Nevara могла стать основой для
*любого* проекта (коммерческого, встраиваемого, образовательного) без условий.

## Кратко о главном

- Написана целиком на Zig, с явным и предсказуемым дизайном.
- Загружается на обычных ПК через GRUB.
- Своя графическая текстовая консоль (1024×768) — читаемая на настоящем
  мониторе.
- Чистое модульное ядро, где каждую часть можно понять.

## Текущее состояние

Два базовых этапа готовы и проверены в QEMU:

- ✅ **Загрузка и инициализация** — загрузка через GRUB в 64-битный режим,
  настройка процессора (сегменты, обработка прерываний и исключений), чтение
  карты памяти машины и вывод на экран.
- ✅ **Управление памятью** — учёт всей физической памяти, виртуальная память
  (таблицы страниц) и растущая куча ядра.

## Планы

Что ещё предстоит сделать (примерно по порядку):

- ⏳ **Процессы и планировщик** — задачи, переключение контекста, планировщик.
- ⏳ **Файловая система и системные вызовы** — слой виртуальной ФС и первые
  Linux-совместимые системные вызовы.
- ⏳ **Userland** — загрузка и запуск настоящих программ, init-система, оболочка.
- ⏳ **Настоящие файловые системы** — чтение и запись реальных дисков.
- ⏳ **Совместимость с Linux** — запуск немодифицированных Linux-программ.
- ⏳ **Доводка** — сеть, нативная файловая система, пользователи и права,
  пакетный менеджер и многое другое.

Это марафон, а не спринт. Прогресс идёт этап за этапом.

## Сборка и запуск

Понадобятся: **Zig 0.16+**, **QEMU**, **GRUB** (`grub-mkrescue`), **xorriso** и
**LLD** (`ld.lld`).

```sh
zig build          # собрать ядро
zig build iso      # собрать загрузочный ISO (zig-out/nevara.iso)
zig build run      # собрать и загрузить в QEMU
```

`zig-out/nevara.iso` также можно запустить в VirtualBox, virt-manager или на
реальном железе. Подойдёт машина с BIOS или UEFI и обычным VGA/QXL/virtio
дисплеем.

## Технические подробности

Глубокие инженерные заметки — архитектура, путь загрузки, особенности линковки и
устройство подсистем — [ниже](#технические-подробности).

## Лицензия

MIT. См. [`LICENSE`](LICENSE) (документация: CC BY 4.0).

---

<a name="технические-подробности"></a>

## Технические подробности (для любопытных)

**Цель сборки:** x86_64, freestanding, в ядре SIMD отключён / soft-float.

**Путь загрузки.** GRUB загружает ядро как Multiboot2-образ и передаёт
управление в 32-битном защищённом режиме. Небольшой ассемблерный трамплин строит
identity-таблицы страниц (первые 4 GiB, страницы по 2 MiB), включает PAE +
long mode + paging, загружает 64-битную GDT и прыгает в точку входа на Zig.

**Система сборки.** Всё описано в одном `build.zig`. Ядро компилируется в один
объектный файл средствами Zig и линкуется **отдельным `ld.lld`** с собственным
скриптом — потому что в этой версии Zig 0.16 self-hosted ELF-линкер игнорирует
пользовательские `SECTIONS` (из-за чего Multiboot2-заголовок уезжал за пределы
32 KiB-окна поиска GRUB), а путь `-flld` падает. Ядро также предоставляет
собственные `memcpy`/`memmove`/`memset`/`memcmp`, так как compiler-rt не
линкуется.

**Графика.** Ядро запрашивает линейный RGB-фреймбуфер (1024×768×32) через
Multiboot2-заголовок и рисует текст масштабированным public-domain шрифтом 8×8.
Весь вывод дублируется в последовательный порт (COM1) для отладки.

**Управление памятью.**

- *Физическая (PMM):* bitmap-аллокатор фреймов, построенный по карте памяти
  Multiboot2; фреймы по 4 KiB; резервирует нижнюю память, образ ядра, сам bitmap
  и boot-информацию.
- *Виртуальная (VMM):* 4-уровневые таблицы страниц; маппинг/размаппинг 4 KiB
  страниц с выделением промежуточных таблиц из PMM; трансляция адресов учитывает
  huge-страницы 2 MiB.
- *Куча:* аллокатор с free-list (first-fit) в виде `std.mem.Allocator`,
  опирается на маппинг страниц по требованию; поддерживает разбиение, слияние и
  произвольное выравнивание.

**Структура исходников.**

```
build.zig            сборка, ISO и запуск в QEMU
boot/grub/           конфигурация GRUB
kernel/
  main.zig           точка входа ядра
  font.zig           битмап-шрифт (public domain)
  arch/x86_64/       трамплин загрузки, GDT/IDT, serial, framebuffer, консоль
  mm/                pmm, vmm, heap
  lib/c.zig          freestanding mem-билтины
```
