const std = @import("std");
const builtin = @import("builtin");
const vkgen = @import("vulkan_zig");
const AssetStep = @import("asset-gen/AssetStep.zig");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const options = .{
        .name = "acid-breakout",
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = optimize,
    };

    const graphics: GraphicsBackend = b.option(
        GraphicsBackend,
        "graphics",
        "Graphics backend to use. Default is Vulkan for Desktop and WebGPU for Web",
    ) orelse if (target.result.os.tag == .emscripten)
        .wgpu
    else
        .vulkan;

    if (target.result.os.tag == .emscripten) {
        const emsdk_root = std.process.getEnvVarOwned(b.allocator, "EMSDK_ROOT") catch |err|
            std.debug.panic("Expected EMSDK_ROOT env to be found: {}", .{err});
        const emscripten_root = b.pathJoin(&[_][]const u8{ emsdk_root, "upstream", "emscripten" });

        const exe_lib = b.addStaticLibrary(options);
        b.installArtifact(exe_lib);

        exe_lib.addSystemIncludePath(.{ .path = b.pathJoin(&[_][]const u8{
            emscripten_root,
            "cache",
            "sysroot",
            "include",
        }) });

        linkLibraries(b, exe_lib, target, graphics);

        const emcc_path = b.pathJoin(&[_][]const u8{ emscripten_root, "emcc" ++ if (builtin.os.tag == .windows) ".bat" else "" });

        // TODO: Remove verbose?
        const emcc_command = b.addSystemCommand(&[_][]const u8{ emcc_path, "-v" });
        emcc_command.addFileArg(exe_lib.getEmittedBin());
        emcc_command.step.dependOn(&exe_lib.step);

        emcc_command.addArgs(&[_][]const u8{
            "-o",
            // TODO: Use proper build output path.
            "zig-out/acid-breakout.html",
            "-sUSE_GLFW=3",
            "-sUSE_WEBGPU",
            "-sUSE_OFFSET_CONVERTER=1",
            "-sALLOW_MEMORY_GROWTH=1",
            "-sASYNCIFY",
            "-sASSERTIONS",
            "-O3",
            "--emrun",
        });

        b.default_step.dependOn(&emcc_command.step);
    } else {
        const exe = b.addExecutable(options);
        b.installArtifact(exe);

        linkLibraries(b, exe, target, graphics);

        const run_cmd = b.addRunArtifact(exe);

        run_cmd.step.dependOn(b.getInstallStep());

        if (b.args) |args| {
            run_cmd.addArgs(args);
        }

        const run_step = b.step("run", "Run the app");
        run_step.dependOn(&run_cmd.step);

        const exe_unit_tests = b.addTest(.{
            .root_source_file = options.root_source_file,
            .target = target,
            .optimize = optimize,
        });

        const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);

        const test_step = b.step("test", "Run unit tests");
        test_step.dependOn(&run_exe_unit_tests.step);
    }
}

const GraphicsBackend = enum {
    vulkan,
    wgpu,
};

fn linkLibraries(
    b: *std.Build,
    compile: *std.Build.Step.Compile,
    target: std.Build.ResolvedTarget,
    graphics: GraphicsBackend,
) void {
    const zlm = b.dependency("zlm", .{});
    compile.root_module.addImport("zlm", zlm.module("zlm"));

    var assets = AssetStep.create(b);
    assets.addAsset(.{ .name = "ball_reflect", .path = "assets/sound/ball-reflect.wav", .tag = .wav });
    assets.addAsset(.{ .name = "ball_free", .path = "assets/sound/ball-free.wav", .tag = .wav });
    compile.root_module.addImport("assets", assets.getModule());

    compile.linkLibC();
    compile.linkLibCpp();

    if (target.result.os.tag != .emscripten) {
        linkGlfw(b, compile, target);
        linkOpenAl(b, compile, target);
    }

    addOptions(b, compile, graphics);

    switch (graphics) {
        .vulkan => {
            linkVulkan(b, compile, target);
            linkVulkanShaders(b, compile);
        },
        .wgpu => linkWgpu(b, compile, target),
    }

    linkImGui(b, compile, target, graphics);
}

fn addOptions(b: *std.Build, compile: *std.Build.Step.Compile, graphics: GraphicsBackend) void {
    const options = b.addOptions();
    options.addOption(GraphicsBackend, "graphics_backend", graphics);
    compile.root_module.addOptions("options", options);
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

fn linkVulkanShaders(b: *std.Build, compile: *std.Build.Step.Compile) void {
    const shaders = vkgen.ShaderCompileStep.create(
        b,
        &[_][]const u8{ "glslc", "--target-env=vulkan1.2" },
        "-o",
    );

    shaders.add("rect_vert", "src/graphics/vulkan/shaders/rect.vert", .{});
    shaders.add("point_vert", "src/graphics/vulkan/shaders/point.vert", .{});
    shaders.add("line_vert", "src/graphics/vulkan/shaders/point.vert", .{ .args = &.{"-DIS_LINE"} });
    shaders.add("main_frag", "src/graphics/vulkan/shaders/main.frag", .{});
    shaders.add("mask_frag", "src/graphics/vulkan/shaders/main.frag", .{ .args = &.{"-DUSE_PIXEL_MASK"} });
    shaders.add("imgui_vert", "src/graphics/vulkan/shaders/imgui.vert", .{});
    shaders.add("imgui_frag", "src/graphics/vulkan/shaders/imgui.frag", .{});
    compile.root_module.addImport("shaders", shaders.getModule());
}

fn linkWgpu(b: *std.Build, compile: *std.Build.Step.Compile, target: std.Build.ResolvedTarget) void {
    compile.addIncludePath(.{ .path = "external/glfw3webgpu" });
    compile.addCSourceFile(.{ .file = .{ .path = "external/glfw3webgpu/glfw3webgpu.c" }, .flags = &[_][]const u8{} });

    if (target.result.os.tag != .emscripten) {
        const wgpu_target = std.mem.concat(b.allocator, u8, &[_][]const u8{ switch (target.result.os.tag) {
            .windows => "windows",
            .macos => "macos",
            .linux => "linux",
            else => |tag| std.debug.panic("Unsupported os: {}", .{tag}),
        }, "-", switch (target.result.cpu.arch) {
            .arm, .aarch64, .aarch64_be, .aarch64_32 => "arm64",
            .x86 => "i686",
            .x86_64 => "x86_64",
            else => |arch| std.debug.panic("Unsupported cpu arch: {}", .{arch}),
        } }) catch @panic("OOM");

        const wgpu_bin_path = b.pathJoin(&[_][]const u8{ "external/wgpu/bin", wgpu_target });
        const wgpu_name = "wgpu_native";

        compile.addIncludePath(.{ .path = "external/wgpu/include" });
        compile.addLibraryPath(.{ .path = wgpu_bin_path });

        switch (target.result.os.tag) {
            .windows => {
                compile.linkSystemLibrary(wgpu_name ++ ".dll");

                const install_lib = installSharedLibWindows(b, wgpu_bin_path, wgpu_name);
                compile.step.dependOn(&install_lib.step);
            },
            .macos => @panic("macos not supported"),
            .linux => {
                compile.linkSystemLibrary(wgpu_name);
            },
            else => unreachable,
        }
    }
}

fn linkImGui(b: *std.Build, compile: *std.Build.Step.Compile, target: std.Build.ResolvedTarget, graphics: GraphicsBackend) void {
    const cimgui_dir = "external/cimgui";
    const cimgui_src = &[_][]const u8{
        "cimgui.cpp",
        "imgui/imgui.cpp",
        "imgui/imgui_demo.cpp",
        "imgui/imgui_draw.cpp",
        "imgui/imgui_tables.cpp",
        "imgui/imgui_widgets.cpp",
        "imgui/backends/imgui_impl_glfw.cpp",
        switch (graphics) {
            .vulkan => "imgui/backends/imgui_impl_vulkan.cpp",
            .wgpu => "imgui/backends/imgui_impl_wgpu.cpp",
        },
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
    if (graphics == .vulkan) {
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
