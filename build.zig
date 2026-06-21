const std = @import("std");

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});

    // Freestanding x86_64 target with SIMD disabled and soft-float enabled.
    // The kernel must not touch SSE/AVX state before it is set up.
    const Feature = std.Target.x86.Feature;
    var sub = std.Target.Cpu.Feature.Set.empty;
    sub.addFeature(@intFromEnum(Feature.mmx));
    sub.addFeature(@intFromEnum(Feature.sse));
    sub.addFeature(@intFromEnum(Feature.sse2));
    sub.addFeature(@intFromEnum(Feature.sse3));
    sub.addFeature(@intFromEnum(Feature.ssse3));
    sub.addFeature(@intFromEnum(Feature.sse4_1));
    sub.addFeature(@intFromEnum(Feature.sse4_2));
    sub.addFeature(@intFromEnum(Feature.avx));
    sub.addFeature(@intFromEnum(Feature.avx2));

    var add = std.Target.Cpu.Feature.Set.empty;
    add.addFeature(@intFromEnum(Feature.soft_float));

    const target = b.resolveTargetQuery(.{
        .cpu_arch = .x86_64,
        .os_tag = .freestanding,
        .abi = .none,
        .cpu_features_sub = sub,
        .cpu_features_add = add,
    });

    // ---- Userspace: build the first init program (static ELF) ----------
    // Linked at a fixed 64 TiB base, so it needs the large code model. It is
    // linked by ld.lld (like the kernel) and embedded into the kernel image.
    const user_mod = b.createModule(.{
        .root_source_file = b.path("user/init.zig"),
        .target = target,
        .optimize = .ReleaseSmall,
        .code_model = .large,
        .red_zone = false,
        .stack_check = false,
        .stack_protector = false,
        .pic = false,
        .strip = true,
    });
    const user_obj = b.addObject(.{ .name = "init", .root_module = user_mod });
    const nstd_mod = b.createModule(.{
        .root_source_file = b.path("user/nstd/nstd.zig"),
        .target = target,
        .optimize = .ReleaseSmall,
        .code_model = .large,
        .red_zone = false,
        .stack_check = false,
        .stack_protector = false,
        .pic = false,
    });
    user_mod.addImport("nstd", nstd_mod);
    const user_link = b.addSystemCommand(&.{ "ld.lld", "-m", "elf_x86_64", "-nostdlib", "-no-pie", "-z", "noexecstack", "-T" });
    user_link.addFileArg(b.path("user/linker.ld"));
    user_link.addArg("-o");
    const user_elf = user_link.addOutputFileArg("init.elf");
    user_link.addFileArg(user_obj.getEmittedBin());

    // NevBox — multi-call userland utility (shares the nstd runtime).
    const nevbox_mod = b.createModule(.{
        .root_source_file = b.path("user/nevbox/nevbox.zig"),
        .target = target,
        .optimize = .ReleaseSmall,
        .code_model = .large,
        .red_zone = false,
        .stack_check = false,
        .stack_protector = false,
        .pic = false,
        .strip = true,
    });
    nevbox_mod.addImport("nstd", nstd_mod);
    const nevbox_obj = b.addObject(.{ .name = "nevbox", .root_module = nevbox_mod });
    const nevbox_link = b.addSystemCommand(&.{ "ld.lld", "-m", "elf_x86_64", "-nostdlib", "-no-pie", "-z", "noexecstack", "-T" });
    nevbox_link.addFileArg(b.path("user/linker.ld"));
    nevbox_link.addArg("-o");
    const nevbox_elf = nevbox_link.addOutputFileArg("nevbox.elf");
    nevbox_link.addFileArg(nevbox_obj.getEmittedBin());

    // ZInit — the init system (PID 1), also on nstd.
    const zinit_mod = b.createModule(.{
        .root_source_file = b.path("user/zinit/zinit.zig"),
        .target = target,
        .optimize = .ReleaseSmall,
        .code_model = .large,
        .red_zone = false,
        .stack_check = false,
        .stack_protector = false,
        .pic = false,
        .strip = true,
    });
    zinit_mod.addImport("nstd", nstd_mod);
    const zinit_obj = b.addObject(.{ .name = "zinit", .root_module = zinit_mod });
    const zinit_link = b.addSystemCommand(&.{ "ld.lld", "-m", "elf_x86_64", "-nostdlib", "-no-pie", "-z", "noexecstack", "-T" });
    zinit_link.addFileArg(b.path("user/linker.ld"));
    zinit_link.addArg("-o");
    const zinit_elf = zinit_link.addOutputFileArg("zinit.elf");
    zinit_link.addFileArg(zinit_obj.getEmittedBin());

    // nsh — the interactive shell.
    const nsh_mod = b.createModule(.{
        .root_source_file = b.path("user/nsh/nsh.zig"),
        .target = target,
        .optimize = .ReleaseSmall,
        .code_model = .large,
        .red_zone = false,
        .stack_check = false,
        .stack_protector = false,
        .pic = false,
        .strip = true,
    });
    nsh_mod.addImport("nstd", nstd_mod);
    const nsh_obj = b.addObject(.{ .name = "nsh", .root_module = nsh_mod });
    const nsh_link = b.addSystemCommand(&.{ "ld.lld", "-m", "elf_x86_64", "-nostdlib", "-no-pie", "-z", "noexecstack", "-T" });
    nsh_link.addFileArg(b.path("user/linker.ld"));
    nsh_link.addArg("-o");
    const nsh_elf = nsh_link.addOutputFileArg("nsh.elf");
    nsh_link.addFileArg(nsh_obj.getEmittedBin());

    // ---- ZLibc: our own C standard library + a C test program ----------
    const zlibc_mod = b.createModule(.{
        .root_source_file = b.path("zlibc/zlibc.zig"),
        .target = target,
        .optimize = .ReleaseSmall,
        .code_model = .large,
        .red_zone = false,
        .stack_check = false,
        .stack_protector = false,
        .pic = false,
    });
    const zlibc_obj = b.addObject(.{ .name = "zlibc", .root_module = zlibc_mod });

    // Compile hello.c with `zig cc` against our headers (no host libc).
    const cc = b.addSystemCommand(&.{ b.graph.zig_exe, "cc" });
    cc.addArgs(&.{
        "-target",          "x86_64-freestanding",
        "-ffreestanding",   "-nostdlib",
        "-nostdinc",        "-fno-stack-protector",
        "-mcmodel=large",   "-O2",
        "-c",
    });
    cc.addPrefixedDirectoryArg("-I", b.path("zlibc/include"));
    cc.addFileArg(b.path("user/hello.c"));
    cc.addArg("-o");
    const hello_o = cc.addOutputFileArg("hello.o");

    const c_link = b.addSystemCommand(&.{ "ld.lld", "-m", "elf_x86_64", "-nostdlib", "-no-pie", "-z", "noexecstack", "-T" });
    c_link.addFileArg(b.path("user/linker.ld"));
    c_link.addArg("-o");
    const hello_elf = c_link.addOutputFileArg("hello.elf");
    c_link.addFileArg(hello_o);
    c_link.addFileArg(zlibc_obj.getEmittedBin());
    // Compile the kernel (Zig + assembly) into a single relocatable object.
    // We do NOT let Zig do the final link:
    //   * Zig's `-flld` path SEGVs on this freestanding target (0.16 bug),
    //   * Zig's self-hosted linker ignores the linker script's SECTIONS, which
    //     pushes the Multiboot2 header out of GRUB's 32 KiB search window.
    // Instead we link explicitly with standalone ld.lld below.
    const kernel_mod = b.createModule(.{
        .root_source_file = b.path("kernel/main.zig"),
        .target = target,
        .optimize = optimize,
        .code_model = .small,
        .red_zone = false,
        .sanitize_c = .off,
        .stack_check = false,
        .stack_protector = false,
        .pic = false,
    });
    kernel_mod.addAssemblyFile(b.path("kernel/arch/x86_64/boot.S"));
    kernel_mod.addAssemblyFile(b.path("kernel/arch/x86_64/flush.S"));
    kernel_mod.addAssemblyFile(b.path("kernel/arch/x86_64/isr.S"));
    kernel_mod.addAssemblyFile(b.path("kernel/arch/x86_64/switch.S"));
    kernel_mod.addAssemblyFile(b.path("kernel/arch/x86_64/usermode.S"));
    kernel_mod.addAssemblyFile(b.path("kernel/arch/x86_64/user_payload.S"));

    // Embed the built init ELF so the kernel can @embedFile("init_elf").
    kernel_mod.addAnonymousImport("init_elf", .{ .root_source_file = user_elf });
    kernel_mod.addAnonymousImport("hello_elf", .{ .root_source_file = hello_elf });
    kernel_mod.addAnonymousImport("nevbox_elf", .{ .root_source_file = nevbox_elf });
    kernel_mod.addAnonymousImport("zinit_elf", .{ .root_source_file = zinit_elf });
    kernel_mod.addAnonymousImport("nsh_elf", .{ .root_source_file = nsh_elf });

    const kernel_obj = b.addObject(.{
        .name = "kernel",
        .root_module = kernel_mod,
    });

    const link = b.addSystemCommand(&.{"ld.lld"});
    link.addArgs(&.{ "-m", "elf_x86_64", "-nostdlib", "-no-pie", "-z", "noexecstack", "-T" });
    link.addFileArg(b.path("kernel/arch/x86_64/linker.ld"));
    link.addArg("-o");
    const kernel_elf = link.addOutputFileArg("kernel");
    link.addFileArg(kernel_obj.getEmittedBin());


    // ---- ext4 rootfs image (ATA primary master) ----------------------------
    // Build a minimal ext4 image containing /bin/* and /etc/hostname.
    // The kernel mounts it as the VFS root on boot.  We rebuild it every
    // time any of the embedded ELF binaries change.

    // Step 1: assemble the rootfs staging directory and create the ext4 image.
    // We pass ELF paths as explicit arguments so Zig can track their changes.
    const mkrootfs = b.addSystemCommand(&.{ "sh", "-c",
        // $1=zinit $2=nsh $3=nevbox $4=hello $5=init $6=output_img
        \\ZINIT="$1" NSH="$2" NEVBOX="$3" HELLO="$4" INIT="$5" OUT="$6"
        \\ROOTFS="$(dirname "$OUT")/rootfsdir"
        \\rm -rf "$ROOTFS"
        \\mkdir -p "$ROOTFS/bin" "$ROOTFS/etc" "$ROOTFS/tmp" "$ROOTFS/mnt" "$ROOTFS/root"

        \\cp "$ZINIT"  "$ROOTFS/bin/zinit"
        \\cp "$NSH"    "$ROOTFS/bin/nsh"
        \\cp "$NEVBOX" "$ROOTFS/bin/nevbox"
        \\cp "$HELLO"  "$ROOTFS/bin/hello"
        \\cp "$INIT"   "$ROOTFS/bin/init"
        \\for APP in echo cat ls mkfile mkdir wc grep head tail cp touch seq tee \
        \\           true false uptime uname nevfetch sort uniq cut tr rev pwd \
        \\           yes basename dirname rm mv sleep; do
        \\    cp "$NEVBOX" "$ROOTFS/bin/$APP"
        \\done
        \\printf 'nevara\n' > "$ROOTFS/etc/hostname"
        \\printf 'root:x:0:0:root:/root:/bin/nsh\n' > "$ROOTFS/etc/passwd"
        \\SIZE_KB=$(du -sk "$ROOTFS" | awk '{print $1}')
        \\IMG_KB=$(( (SIZE_KB + 4096 + 1023) / 1024 * 1024 ))
        \\[ "$IMG_KB" -lt 65536 ] && IMG_KB=65536
        \\mke2fs -q -F -t ext4 -b 1024 \
        \\       -O ^has_journal,^metadata_csum,^64bit,^dir_index \
        \\       -d "$ROOTFS" "$OUT" "${IMG_KB}"
        \\debugfs -w -R 'unlink lost+found' "$OUT" 2>/dev/null || true
        , "--",
    });
    mkrootfs.addFileArg(zinit_elf);
    mkrootfs.addFileArg(nsh_elf);
    mkrootfs.addFileArg(nevbox_elf);
    mkrootfs.addFileArg(hello_elf);
    mkrootfs.addFileArg(user_elf);
    const rootfs_img = mkrootfs.addOutputFileArg("rootfs.ext4");

    // ---- Bootable ISO via grub-mkrescue --------------------------------
    const iso_tree = "iso";
    const install_kernel = b.addInstallFileWithDir(
        kernel_elf,
        .{ .custom = iso_tree },
        "boot/kernel",
    );
    const install_cfg = b.addInstallFileWithDir(
        b.path("boot/grub/grub.cfg"),
        .{ .custom = iso_tree },
        "boot/grub/grub.cfg",
    );
    // Embed the rootfs image inside the ISO so it is distributed in one file.
    const install_rootfs = b.addInstallFileWithDir(
        rootfs_img,
        .{ .custom = iso_tree },
        "boot/rootfs.ext4",
    );

    const mkrescue = b.addSystemCommand(&.{"grub-mkrescue"});
    mkrescue.addArg("-o");
    const iso_file = mkrescue.addOutputFileArg("nevara.iso");
    mkrescue.addArg(b.getInstallPath(.{ .custom = iso_tree }, ""));
    mkrescue.step.dependOn(&install_kernel.step);
    mkrescue.step.dependOn(&install_cfg.step);
    mkrescue.step.dependOn(&install_rootfs.step);
    mkrescue.addFileInput(kernel_elf);
    mkrescue.addFileInput(b.path("boot/grub/grub.cfg"));
    mkrescue.addFileInput(rootfs_img);

    const install_iso = b.addInstallFile(iso_file, "nevara.iso");
    const iso_step = b.step("iso", "Build a bootable GRUB ISO (kernel + ext4 rootfs)");
    iso_step.dependOn(&install_iso.step);

    const install_kernel_bin = b.addInstallBinFile(kernel_elf, "kernel");
    b.getInstallStep().dependOn(&install_kernel_bin.step);

    // ---- Run in QEMU ----------------------------------------------------
    // Extract the rootfs from the ISO into zig-out/ for the -drive argument.
    // We copy it from the build cache so QEMU always sees a fresh image.
    const cp_rootfs = b.addSystemCommand(&.{ "sh", "-c",
        "mkdir -p zig-out && cp \"$1\" zig-out/rootfs.ext4", "--",
    });
    cp_rootfs.addFileArg(rootfs_img);
    cp_rootfs.step.dependOn(&mkrootfs.step);

    const run = b.addSystemCommand(&.{"qemu-system-x86_64"});
    run.addArg("-cdrom");
    run.addFileArg(iso_file);
    run.addArgs(&.{
        "-serial",    "stdio",
        "-no-reboot", "-no-shutdown",
        "-m",         "512M",
        "-vga",       "std",
        "-boot",      "d",
        // ext4 rootfs on ATA primary master (drive 0) — the kernel mounts
        // it as the root filesystem via the read-only ext4 driver.
        "-drive",     "file=zig-out/rootfs.ext4,format=raw,if=ide,index=0,media=disk",
    });
    run.step.dependOn(&cp_rootfs.step);
    const run_step = b.step("run", "Boot Nevara OS in QEMU");
    run_step.dependOn(&run.step);
}
