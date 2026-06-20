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

    const install_kernel_bin = b.addInstallBinFile(kernel_elf, "kernel");
    b.getInstallStep().dependOn(&install_kernel_bin.step);

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

    const mkrescue = b.addSystemCommand(&.{"grub-mkrescue"});
    mkrescue.addArg("-o");
    const iso_file = mkrescue.addOutputFileArg("nevara.iso");
    mkrescue.addArg(b.getInstallPath(.{ .custom = iso_tree }, ""));
    mkrescue.step.dependOn(&install_kernel.step);
    mkrescue.step.dependOn(&install_cfg.step);
    // The directory is a plain string arg, so Zig can't see its contents
    // change. Declare the real inputs so the ISO rebuilds when they change.
    mkrescue.addFileInput(kernel_elf);
    mkrescue.addFileInput(b.path("boot/grub/grub.cfg"));

    const install_iso = b.addInstallFile(iso_file, "nevara.iso");
    const iso_step = b.step("iso", "Build a bootable GRUB ISO");
    iso_step.dependOn(&install_iso.step);

    // ---- Run in QEMU ----------------------------------------------------
    const run = b.addSystemCommand(&.{"qemu-system-x86_64"});
    run.addArg("-cdrom");
    run.addFileArg(iso_file);
    run.addArgs(&.{
        "-serial",    "stdio",
        "-no-reboot", "-no-shutdown",
        "-m",         "512M",
        "-vga",       "std",
    });
    const run_step = b.step("run", "Boot Nevara OS in QEMU");
    run_step.dependOn(&run.step);
}
