const std = @import("std");
const vkgen = @import("vulkan_zig");
const AssetStep = @import("asset-gen/AssetStep.zig");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "acid-breakout",
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = optimize,
    });

    var assets = AssetStep.create(b);
    assets.addAsset(.{ .name = "ball_reflect", .path = "assets/sound/ball-reflect.wav", .tag = .wav });
    exe.root_module.addImport("assets", assets.getModule());

    exe.linkLibC();
    exe.linkLibCpp();

    linkGlfw(b, exe, target);
    linkOpenAl(b, exe, target);
    linkVulkan(b, exe, target);
    linkShaders(b, exe);
    linkImGui(b, exe, target);

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);

    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const exe_unit_tests = b.addTest(.{
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = optimize,
    });

    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_exe_unit_tests.step);
}

fn linkGlfw(b: *std.Build, compile: *std.Build.Step.Compile, target: std.Build.ResolvedTarget) void {
    // Try to link libs using vcpkg on Windows
    if (target.result.os.tag == .windows) {
        const vcpkg_root = std.process.getEnvVarOwned(b.allocator, "VCPKG_ROOT") catch |err|
            std.debug.panic("Expected VCPKG_ROOT env to be found: {}", .{err});

        const arch_str = switch (target.result.cpu.arch) {
            .x86 => "x86",
            .x86_64 => "x64",
            .arm, .aarch64_32 => "arm",
            .aarch64 => "arm64",
            .wasm32 => "wasm32",
            else => std.debug.panic("Unsupported CPU architecture: {}", .{target.result.cpu.arch}),
        };

        const vcpkg_installed_arch_path = b.pathJoin(&[_][]const u8{
            vcpkg_root,
            "installed",
            std.mem.concat(b.allocator, u8, &[_][]const u8{ arch_str, "-windows" }) catch unreachable,
        });

        const vcpkg_lib_path = b.pathJoin(&[_][]const u8{ vcpkg_installed_arch_path, "lib" });
        const vcpkg_include_path = b.pathJoin(&[_][]const u8{ vcpkg_installed_arch_path, "include" });

        const lib_name = "glfw3";

        compile.addIncludePath(.{ .path = vcpkg_include_path });
        compile.addLibraryPath(.{ .path = vcpkg_lib_path });
        compile.linkSystemLibrary(lib_name ++ "dll");

        const vcpkg_bin_path = b.pathJoin(&[_][]const u8{ vcpkg_installed_arch_path, "bin" });

        const install_lib = installSharedLibWindows(b, vcpkg_bin_path, lib_name);
        compile.step.dependOn(&install_lib.step);
    } else {
        compile.linkSystemLibrary("glfw");
    }
}

fn linkOpenAl(b: *std.Build, compile: *std.Build.Step.Compile, target: std.Build.ResolvedTarget) void {
    // Try to link libs using vcpkg on Windows
    if (target.result.os.tag == .windows) {
        const vcpkg_root = std.process.getEnvVarOwned(b.allocator, "VCPKG_ROOT") catch |err|
            std.debug.panic("Expected VCPKG_ROOT env to be found: {}", .{err});

        const arch_str = switch (target.result.cpu.arch) {
            .x86 => "x86",
            .x86_64 => "x64",
            .arm, .aarch64_32 => "arm",
            .aarch64 => "arm64",
            .wasm32 => "wasm32",
            else => std.debug.panic("Unsupported CPU architecture: {}", .{target.result.cpu.arch}),
        };

        const vcpkg_installed_arch_path = b.pathJoin(&[_][]const u8{
            vcpkg_root,
            "installed",
            std.mem.concat(b.allocator, u8, &[_][]const u8{ arch_str, "-windows" }) catch unreachable,
        });

        const vcpkg_lib_path = b.pathJoin(&[_][]const u8{ vcpkg_installed_arch_path, "lib" });
        const vcpkg_include_path = b.pathJoin(&[_][]const u8{ vcpkg_installed_arch_path, "include" });

        const lib_name = "OpenAL32";

        compile.addIncludePath(.{ .path = vcpkg_include_path });
        compile.addLibraryPath(.{ .path = vcpkg_lib_path });
        compile.linkSystemLibrary(lib_name);

        const vcpkg_bin_path = b.pathJoin(&[_][]const u8{ vcpkg_installed_arch_path, "bin" });

        const install_lib = installSharedLibWindows(b, vcpkg_bin_path, lib_name);
        compile.step.dependOn(&install_lib.step);
    } else {
        compile.linkSystemLibrary("openal");
    }
}

fn linkVulkan(b: *std.Build, compile: *std.Build.Step.Compile, target: std.Build.ResolvedTarget) void {
    const sdk_root_env = std.process.getEnvVarOwned(b.allocator, "VULKAN_SDK") catch null;
    const share_parent_dir = if (sdk_root_env) |root|
        root
    else if (target.result.os.tag != .windows)
        "/usr"
    else
        @panic("Failed to find Vulkan share directory. Please set the VULKAN_SDK environment variable.");

    const registry_path = b.pathJoin(&[_][]const u8{
        share_parent_dir,
        "share",
        "vulkan",
        "registry",
        "vk.xml",
    });

    const vkzig = b.dependency("vulkan_zig", .{ .registry = @as([]const u8, registry_path) });
    const vkzig_bindings = vkzig.module("vulkan-zig");
    compile.root_module.addImport("vulkan", vkzig_bindings);
}

fn linkShaders(b: *std.Build, compile: *std.Build.Step.Compile) void {
    const shaders = vkgen.ShaderCompileStep.create(
        b,
        &[_][]const u8{ "glslc", "--target-env=vulkan1.2" },
        "-o",
    );

    shaders.add("triangle_vert", "src/shaders/triangle.vert", .{});
    shaders.add("triangle_frag", "src/shaders/triangle.frag", .{});
    shaders.add("imgui_vert", "src/shaders/imgui.vert", .{});
    shaders.add("imgui_frag", "src/shaders/imgui.frag", .{});
    compile.root_module.addImport("shaders", shaders.getModule());
}

fn linkImGui(b: *std.Build, compile: *std.Build.Step.Compile, target: std.Build.ResolvedTarget) void {
    const cimgui_dir = "external/cimgui";
    const cimgui_src = &[_][]const u8{
        "cimgui.cpp",
        "imgui/imgui.cpp",
        "imgui/imgui_demo.cpp",
        "imgui/imgui_draw.cpp",
        "imgui/imgui_tables.cpp",
        "imgui/imgui_widgets.cpp",
        "imgui/backends/imgui_impl_glfw.cpp",
        "imgui/backends/imgui_impl_vulkan.cpp",
    };
    const cxx_flags = &[_][]const u8{
        "-std=c++20",
        "-DIMGUI_IMPL_API=extern \"C\"",
    };

    for (cimgui_src) |src_file| {
        compile.addCSourceFile(.{
            .file = .{ .path = b.pathJoin(&[_][]const u8{ cimgui_dir, src_file }) },
            .flags = cxx_flags,
        });
    }

    compile.addIncludePath(.{ .path = cimgui_dir });
    compile.addIncludePath(.{ .path = b.pathJoin(&[_][]const u8{ cimgui_dir, "generator", "output" }) });
    compile.addIncludePath(.{ .path = b.pathJoin(&[_][]const u8{ cimgui_dir, "imgui" }) });

    // Link system Vulkan lib for the ImGui Vulkan impl to use.
    if (target.result.os.tag == .windows) {
        const vulkan_sdk_root = std.process.getEnvVarOwned(b.allocator, "VULKAN_SDK") catch |err| {
            std.debug.panic("Expected VULKAN_SDK env to be found, but got: {}", .{err});
        };

        const arch_suffix = switch (target.result.cpu.arch) {
            .x86 => "32",
            .x86_64 => "",
            else => std.debug.panic("Expected x86 CPU architecture, but got: {}", .{target.result.cpu.arch}),
        };

        const lib_dir_name = std.mem.concat(b.allocator, u8, &[_][]const u8{ "Lib", arch_suffix }) catch @panic("OOM");

        compile.addIncludePath(.{ .path = b.pathJoin(&[_][]const u8{ vulkan_sdk_root, "Include" }) });
        compile.addLibraryPath(.{ .path = b.pathJoin(&[_][]const u8{ vulkan_sdk_root, lib_dir_name }) });
        compile.linkSystemLibrary("vulkan-1");
    } else {
        compile.linkSystemLibrary("vulkan");
    }
}

fn installSharedLibWindows(b: *std.Build, src_dir: []const u8, lib_name: []const u8) *std.Build.Step.InstallFile {
    const dll_name = b.fmt("{s}{s}", .{ lib_name, ".dll" });
    const dll_path = b.pathJoin(&[_][]const u8{ src_dir, dll_name });

    const pdb_name = b.fmt("{s}{s}", .{ lib_name, ".pdb" });
    const pdb_path = b.pathJoin(&[_][]const u8{ src_dir, pdb_name });

    const install_dll = b.addInstallBinFile(.{ .path = dll_path }, dll_name);

    // Make sure pdb file exists before trying to install it
    if (std.fs.cwd().openFile(pdb_path, .{})) |pdb_file| {
        pdb_file.close();

        const install_pdb = b.addInstallBinFile(.{ .path = pdb_path }, pdb_name);
        install_dll.step.dependOn(&install_pdb.step);
    } else |_| {}

    return install_dll;
}
