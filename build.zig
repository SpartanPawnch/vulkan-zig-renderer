const std = @import("std");
// const vkgen = @import("deps/vulkan-zig/generator/index.zig");

pub fn build(b: *std.Build) !void {
    // const target = b.standardTargetOptions(.{});
    // const mode = b.standardReleaseOptions();

    const exe = b.addExecutable(.{
        .name = "renderer",
        .root_source_file = .{ .path = "src/main.zig" },
        .target = b.host,
    });

    //add zgltf
    const zgltf = b.addModule("zgltf", .{ .root_source_file = .{ .path = "deps/zgltf/src/main.zig" } });
    // exe.addModule("zgltf", zgltf);
    exe.root_module.addImport("zgltf", zgltf);

    //add zlm
    // const zlm = b.addModule("zlm", .{ .source_file = .{ .path = "deps/zlm/src/zlm.zig" } });
    // exe.addModule("zlm", zlm);
    const za = b.addModule("zalgebra", .{ .root_source_file = .{ .path = "deps/zalgebra/src/main.zig" } });
    exe.root_module.addImport("zalgebra", za);

    //add c deps
    exe.linkLibC();
    exe.linkLibCpp();
    exe.linkSystemLibrary("glfw");
    exe.linkSystemLibrary("vulkan");
    exe.addSystemIncludePath(std.Build.LazyPath{ .path = "deps/vma" });
    exe.addSystemIncludePath(std.Build.LazyPath{ .path = "deps/stb_image" });
    exe.addCSourceFile(.{ .file = .{ .path = "src/vk_mem_alloc.cpp" }, .flags = &.{""} });
    exe.addCSourceFile(.{ .file = .{ .path = "src/stbi.c" }, .flags = &.{""} });

    b.default_step.dependOn(&exe.step);
    b.installArtifact(exe);
    b.installDirectory(.{
        .source_dir = .{ .path = "assets" },
        .install_dir = .bin,
        .install_subdir = "assets",
    });

    const run_exe = b.addRunArtifact(exe);
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_exe.step);

    try addShader(b, exe, "triangle.vert", "triangle_vert.spv");
    try addShader(b, exe, "triangle.frag", "triangle_frag.spv");
}

fn addShader(b: *std.Build, exe: anytype, in_file: []const u8, out_file: []const u8) !void {
    // example:
    // glslc -o shaders/vert.spv shaders/shader.vert
    const dirname = "src/shaders";
    const full_in = try std.fs.path.join(b.allocator, &[_][]const u8{ dirname, in_file });
    const full_out = try std.fs.path.join(b.allocator, &[_][]const u8{ dirname, out_file });

    const run_cmd = b.addSystemCommand(&[_][]const u8{
        "glslc",
        "-o",
        full_out,
        full_in,
    });
    exe.step.dependOn(&run_cmd.step);
}
