const std = @import("std");

pub fn build(b: *std.Build) !void {
    const exe = b.addExecutable(.{
        .name = "renderer",
        .root_source_file = b.path("src/main.zig"),
        .target = b.host,
    });

    //add zgltf
    const zgltf = b.addModule("zgltf", .{ .root_source_file = b.path("deps/zgltf/src/main.zig") });
    exe.root_module.addImport("zgltf", zgltf);

    //add zlm
    const za = b.addModule("zalgebra", .{ .root_source_file = b.path("deps/zalgebra/src/main.zig") });
    exe.root_module.addImport("zalgebra", za);

    //add c deps
    exe.linkLibC();
    exe.linkLibCpp();
    exe.linkSystemLibrary("glfw");
    exe.linkSystemLibrary("vulkan");
    exe.addSystemIncludePath(b.path("deps/vma"));
    exe.addSystemIncludePath(b.path("deps/stb_image"));
    exe.addCSourceFile(.{ .file = b.path("src/vk_mem_alloc.cpp") });
    exe.addCSourceFile(.{ .file = b.path("src/stbi.c") });

    b.default_step.dependOn(&exe.step);
    b.installArtifact(exe);
    b.installDirectory(.{
        .source_dir = b.path("assets"),
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
