const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.resolveTargetQuery(.{
        .cpu_arch = .x86_64,
        .os_tag = .uefi,
        .abi = .msvc,
    });

    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "BOOTX64",
        .root_source_file = b.path("BOOT/BOOTX64.zig"),
        .target = target,
        .optimize = optimize,
        .strip = true,
    });

    exe.subsystem = .EfiApplication;

    b.installArtifact(exe);
}
