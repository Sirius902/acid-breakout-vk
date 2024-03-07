const std = @import("std");
const builtin = @import("builtin");
const options = @import("options");
const c = @import("c.zig");
const zlm = @import("zlm");
const assets = @import("assets");
const math = @import("math.zig");
const AudioContext = @import("audio_context.zig").AudioContext;
const InputContext = @import("InputContext.zig");
const Game = @import("game/game.zig").Game;
const DrawList = @import("game/game.zig").DrawList;
const Allocator = std.mem.Allocator;
const vec2 = zlm.vec2;
const vec2u = math.vec2u;

const GraphicsBackend = switch (options.graphics_backend) {
    .vulkan => @import("graphics/vulkan/Backend.zig"),
    .wgpu => @import("graphics/wgpu/Backend.zig"),
};

const app_name = "Acid Breakout";

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){ .backing_allocator = std.heap.c_allocator };
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const exe_dir_path = if (builtin.os.tag == .emscripten)
        null
    else
        std.fs.selfExeDirPathAlloc(allocator) catch |err| blk: {
            std.log.err("Failed to get exe dir path: {}", .{err});
            break :blk null;
        };
    defer if (exe_dir_path) |path| allocator.free(path);

    var exe_dir: ?std.fs.Dir = if (builtin.os.tag == .emscripten)
        std.fs.cwd()
    else if (exe_dir_path) |path|
        std.fs.openDirAbsolute(path, .{}) catch |err| blk: {
            std.log.err("Failed to open exe dir: {}", .{err});
            break :blk null;
        }
    else
        null;
    defer if (exe_dir) |*dir| dir.close();

    var config: Config = if (exe_dir) |*dir|
        Config.loadOrDefault(dir, allocator)
    else blk: {
        std.log.err("Expected exe dir path to exist when loading config", .{});
        break :blk .{};
    };

    if (c.glfwInit() != c.GLFW_TRUE) return error.GlfwInitFailed;
    defer c.glfwTerminate();

    _ = c.glfwSetErrorCallback(glfwErrorCallback);

    const initial_width = 800;
    const initial_height = 600;

    // Synchronization is not required to access inputs on the thread that polls GLFW events.
    var input = InputContext.init();

    c.glfwWindowHint(c.GLFW_CLIENT_API, c.GLFW_NO_API);
    const window = c.glfwCreateWindow(
        initial_width,
        initial_height,
        app_name,
        null,
        null,
    ) orelse return error.WindowInitFailed;
    defer c.glfwDestroyWindow(window);

    _ = c.glfwSetWindowUserPointer(window, &input);
    _ = c.glfwSetCursorPosCallback(window, glfwCursorPosCallback);
    _ = c.glfwSetKeyCallback(window, glfwKeyCallback);

    const imgui_ini_name = "imgui.ini";
    const imgui_ini_path = if (exe_dir_path) |path|
        try std.fs.path.joinZ(
            allocator,
            &[_][]const u8{ path, imgui_ini_name },
        )
    else blk: {
        std.log.err("Expected exe dir path to exist when making ImGui ini path", .{});
        break :blk imgui_ini_name;
    };
    defer allocator.free(imgui_ini_path);

    igInit(imgui_ini_path);
    defer igDeinit();

    var gfx = try GraphicsBackend.init(allocator, window, app_name, config.wait_for_vsync);
    defer gfx.deinit();

    var ac = try AudioContext.init(allocator);
    defer ac.deinit();

    if (config.volume) |volume| ac.setListenerGain(volume);
    if (config.pitch_variance) |pv| ac.setSourcePitchVariance(pv);

    try ac.cacheSound(&assets.ball_reflect);
    try ac.cacheSound(&assets.ball_free);

    var game = try Game.init(vec2u(initial_width, initial_height), allocator);
    defer game.deinit();

    var draw_list = DrawList.init(allocator);
    defer draw_list.deinit();

    var frame_timer = std.time.Timer.start() catch @panic("Expected timer to be supported");
    while (c.glfwWindowShouldClose(window) == c.GLFW_FALSE) {
        if (builtin.target.os.tag == .emscripten) {
            // TODO: Use emscripten_request_animation_frame_loop.
            const em = @cImport(@cInclude("emscripten.h"));
            em.emscripten_sleep(16);
        }

        var ww: c_int = undefined;
        var wh: c_int = undefined;
        c.glfwGetWindowSize(window, &ww, &wh);
        const window_size = vec2(@floatFromInt(ww), @floatFromInt(wh));

        // TODO: Figure out what else needs to be done to work properly on high DPI displays.
        var fw: c_int = undefined;
        var fh: c_int = undefined;
        c.glfwGetFramebufferSize(window, &fw, &fh);

        // Scale mouse position to correspond to game units within the aspected viewport.
        const mouse_pos = if (input.mouseState().pos) |p| blk: {
            const game_size = math.vec2Cast(f32, game.size);
            const unit_pos = p.div(window_size).mul(vec2(1, -1)).add(vec2(0, 1)).sub(zlm.Vec2.one.scale(0.5));
            const aspect_ratio = (window_size.x / game_size.x) / (window_size.y / game_size.y);
            const scaled_pos = if (ww >= wh)
                unit_pos.mul(vec2(game_size.x * aspect_ratio, game_size.y))
            else
                unit_pos.mul(vec2(game_size.x, game_size.y / aspect_ratio));
            break :blk scaled_pos.add(game_size.scale(0.5));
        } else null;

        game.updateInput(mouse_pos, input.keyState(.escape).isDown());
        const tick_result = game.tick(frame_timer.lap());
        var sound_iterator = tick_result.sound_list.iterator();
        while (sound_iterator.next()) |kv| {
            try ac.playSound(kv.key_ptr);
        }

        // Don't present or resize swapchain while the window is minimized.
        if (fw == 0 or fh == 0) {
            c.glfwPollEvents();
            continue;
        }

        try igFrame(allocator, &input, ac, &gfx, &config, &game, window, if (exe_dir) |*d| d else null);

        draw_list.clear();
        try game.draw(&draw_list);

        try gfx.renderFrame(&game, &draw_list);

        // Tick audio synchronously on emscripten as there is no threading.
        if (builtin.os.tag == .emscripten) {
            try ac.tickAudio();
        }

        c.glfwPollEvents();
    }
}

const Config = struct {
    wait_for_vsync: bool = true,
    is_config_open: bool = true,
    volume: ?f32 = null,
    pitch_variance: ?f32 = null,
    dev: struct {
        ball_spawn_count: usize = 8000,
    } = .{},

    pub const file_name = "acid-breakout.json";

    pub fn loadOrDefault(dir: *std.fs.Dir, allocator: Allocator) Config {
        var file = dir.openFile(file_name, .{}) catch |err| {
            switch (err) {
                error.FileNotFound => std.log.info("{s} not found, using default config", .{file_name}),
                else => std.log.err("Failed to open {s} with {}, using default config", .{ file_name, err }),
            }
            return .{};
        };
        defer file.close();

        var json_reader = std.json.reader(allocator, file.reader());
        defer json_reader.deinit();

        const parsed = std.json.parseFromTokenSource(Config, allocator, &json_reader, .{}) catch |err| {
            std.log.err("Expected parsing {s} as JSON to succeed, but got: {}", .{ file_name, err });
            return .{};
        };
        defer parsed.deinit();
        std.log.info("Loaded config from {s}", .{file_name});
        return parsed.value.sanitize();
    }

    pub fn trySave(self: Config, dir: *std.fs.Dir) void {
        var file = dir.createFile(file_name, .{}) catch |err| {
            std.log.err("Failed to open {s} for writing: {}", .{ file_name, err });
            return;
        };
        defer file.close();

        var json_writer = std.json.writeStream(file.writer(), .{ .whitespace = .indent_2 });
        json_writer.write(self.sanitize()) catch |err| {
            std.log.err("Failed to write config as JSON: {}", .{err});
        };
    }

    fn sanitize(self: Config) Config {
        var config = self;
        if (config.volume) |*volume| volume.* = std.math.clamp(volume.*, 0, 1);
        if (config.pitch_variance) |*pv| pv.* = std.math.clamp(pv.*, 0, 1);
        return config;
    }
};

fn glfwErrorCallback(error_code: c_int, description: [*c]const u8) callconv(.C) void {
    std.log.err("GLFW error {}: {s}", .{ error_code, description });
}

fn glfwCursorPosCallback(window: ?*c.GLFWwindow, x: f64, y: f64) callconv(.C) void {
    const input: *InputContext = @ptrCast(@alignCast(c.glfwGetWindowUserPointer(window).?));
    input.updateMouse(vec2(@floatCast(x), @floatCast(y)));
}

fn glfwKeyCallback(window: ?*c.GLFWwindow, key: c_int, scancode: c_int, action: c_int, mods: c_int) callconv(.C) void {
    _ = scancode;
    _ = mods;

    const input_key: ?InputContext.Key = switch (key) {
        c.GLFW_KEY_F1 => .f1,
        c.GLFW_KEY_ESCAPE => .escape,
        else => null,
    };

    if (input_key) |k| {
        const input_state: InputContext.KeyState = switch (action) {
            c.GLFW_PRESS => .press,
            c.GLFW_RELEASE => .release,
            c.GLFW_REPEAT => .repeat,
            else => std.debug.panic("Unexpected GLFW key action: {}", .{action}),
        };

        const input: *InputContext = @ptrCast(@alignCast(c.glfwGetWindowUserPointer(window).?));
        input.updateKey(k, input_state);
    }
}

fn igInit(ini_path: [*:0]const u8) void {
    _ = c.igCreateContext(null);
    errdefer c.igDestroyContext(null);

    const io: *c.ImGuiIO = c.igGetIO();
    io.IniFilename = ini_path;
    io.ConfigFlags |= c.ImGuiConfigFlags_NavEnableKeyboard;
    io.ConfigFlags |= c.ImGuiConfigFlags_NavEnableGamepad;
    io.ConfigFlags |= c.ImGuiConfigFlags_DockingEnable;
    // io.ConfigFlags |= c.ImGuiConfigFlags_ViewportsEnable;

    // When viewports are enabled we tweak WindowRounding/WindowBg so platform windows can look identical to regular ones.
    const style: *c.ImGuiStyle = c.igGetStyle();
    if ((io.ConfigFlags & c.ImGuiConfigFlags_ViewportsEnable) != 0) {
        style.WindowRounding = 0.0;
        style.Colors[c.ImGuiCol_WindowBg].w = 1.0;
    }

    c.igStyleColorsDark(null);
}

fn igDeinit() void {
    c.ImGui_ImplGlfw_Shutdown();
    c.igDestroyContext(null);
}

fn igFrame(
    allocator: Allocator,
    input: *const InputContext,
    ac: *AudioContext,
    gfx: *GraphicsBackend,
    config: *Config,
    game: *Game,
    window: *c.GLFWwindow,
    exe_dir: ?*std.fs.Dir,
) !void {
    const state = struct {
        pub var is_demo_open = false;
        pub var is_f1_down = false;
    };

    GraphicsBackend.igImplNewFrame();
    c.ImGui_ImplGlfw_NewFrame();
    c.igNewFrame();

    var fw: c_int = undefined;
    var fh: c_int = undefined;
    c.glfwGetFramebufferSize(window, &fw, &fh);

    var is_save_config = false;

    const f1 = input.keyState(.f1).isDown();
    if (!state.is_f1_down and f1) {
        config.is_config_open = !config.is_config_open;
        is_save_config = true;
    }
    state.is_f1_down = f1;

    if (state.is_demo_open) c.igShowDemoWindow(&state.is_demo_open);
    if (config.is_config_open) {
        var is_open = config.is_config_open;
        if (c.igBegin(app_name, &is_open, c.ImGuiWindowFlags_None)) {
            defer {
                c.igEnd();
                if (config.is_config_open != is_open) {
                    config.is_config_open = is_open;
                    is_save_config = true;
                }
            }

            {
                const status = if (game.is_paused) "Paused" else "Playing";
                const status_text = try std.fmt.allocPrint(allocator, "Status: {s}", .{status});
                defer allocator.free(status_text);

                c.igTextUnformatted(status_text.ptr, @as([*]u8, status_text.ptr) + status_text.len);
            }

            {
                const backend = switch (options.graphics_backend) {
                    .vulkan => "Vulkan",
                    .wgpu => "WebGPU",
                };
                const backend_text = try std.fmt.allocPrint(allocator, "Graphics Backend: {s}", .{backend});
                defer allocator.free(backend_text);

                c.igTextUnformatted(backend_text.ptr, @as([*]u8, backend_text.ptr) + backend_text.len);
            }

            {
                const avg_tps = @round(game.averageTps() * 10) / 10;
                const avg_tps_text = try std.fmt.allocPrint(allocator, "Average TPS: {d:.1}", .{avg_tps});
                defer allocator.free(avg_tps_text);

                c.igTextUnformatted(avg_tps_text.ptr, @as([*]u8, avg_tps_text.ptr) + avg_tps_text.len);
            }

            {
                const avg_audiotick = @round(ac.averageTps() * 10) / 10;
                const avg_audiotick_text = try std.fmt.allocPrint(allocator, "Average Audio TPS: {d:.1}", .{avg_audiotick});
                defer allocator.free(avg_audiotick_text);

                c.igTextUnformatted(avg_audiotick_text.ptr, @as([*]u8, avg_audiotick_text.ptr) + avg_audiotick_text.len);
            }

            {
                const time = @round(game.time * 10) / 10;
                const time_text = try std.fmt.allocPrint(allocator, "Time: {d:.1}s", .{time});
                defer allocator.free(time_text);

                c.igTextUnformatted(time_text.ptr, @as([*]u8, time_text.ptr) + time_text.len);
            }

            {
                const pixels_remaining_text = try std.fmt.allocPrint(allocator, "Pixels Remaining: {} / {}", .{ game.strip.numPixelsRemaining(), game.strip.numTotalPixels() });
                defer allocator.free(pixels_remaining_text);

                c.igTextUnformatted(pixels_remaining_text.ptr, @as([*]u8, pixels_remaining_text.ptr) + pixels_remaining_text.len);
            }

            {
                const particle_count_text = try std.fmt.allocPrint(allocator, "Particle Count: {}", .{game.balls.len});
                defer allocator.free(particle_count_text);

                c.igTextUnformatted(particle_count_text.ptr, @as([*]u8, particle_count_text.ptr) + particle_count_text.len);
            }

            if (c.igButton("Reset Game", .{ .x = 0, .y = 0 })) {
                game.reset(vec2u(@intCast(fw), @intCast(fh)));
            }

            if (c.igCheckbox("Wait for VSync", &config.wait_for_vsync)) {
                gfx.wait_for_vsync = config.wait_for_vsync;
                gfx.is_graphics_outdated = true;
                is_save_config = true;
            }

            var volume = config.volume orelse ac.getListenerGain();
            if (c.igSliderFloat("Volume", &volume, 0, 1, "%.2f", 0)) {
                config.volume = volume;
                ac.setListenerGain(volume);
                is_save_config = true;
            }

            if (c.igButton("Reset Volume", .{ .x = 0, .y = 0 })) {
                config.volume = null;
                ac.setListenerGain(AudioContext.default_listener_gain);
                is_save_config = true;
            }

            var variance = config.pitch_variance orelse ac.getSourcePitchVariance();
            if (c.igSliderFloat("Pitch Variance", &variance, 0, 1, "%.2f", 0)) {
                config.pitch_variance = variance;
                ac.setSourcePitchVariance(variance);
                is_save_config = true;
            }

            if (c.igButton("Reset Pitch Variance", .{ .x = 0, .y = 0 })) {
                config.pitch_variance = null;
                ac.setSourcePitchVariance(AudioContext.default_source_pitch_variance);
                is_save_config = true;
            }

            if (c.igButton("Play Sound", .{ .x = 0, .y = 0 })) {
                ac.playSound(&assets.ball_reflect.hash) catch |err| std.log.err("Failed to play sound: {}", .{err});
            }

            {
                var input_buf: [math.maxDigits(usize) + 1]u8 = undefined;
                _ = std.fmt.bufPrintZ(&input_buf, "{}", .{config.dev.ball_spawn_count}) catch unreachable;

                if (c.igInputText("Spawn Count", &input_buf, input_buf.len, 0, null, null)) {
                    const str = std.mem.span(@as([*:0]u8, @ptrCast(&input_buf)));
                    if (!std.mem.containsAtLeast(u8, str, 1, "_")) {
                        if (std.fmt.parseInt(usize, str, 10)) |n| {
                            config.dev.ball_spawn_count = n;
                            is_save_config = true;
                        } else |_| {}
                    }
                }
            }

            if (c.igButton("Spawn Particles", .{ .x = 0, .y = 0 })) {
                const size_f = math.vec2Cast(f32, game.size);
                for (0..config.dev.ball_spawn_count) |i| {
                    const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(config.dev.ball_spawn_count));
                    game.spawnBall(.{
                        .start_pos = vec2(std.math.lerp(0.0, size_f.x, t), 0.5 * size_f.y),
                        .random_x_vel = false,
                    });
                }
            }

            if (c.igButton("Open Demo Window", .{ .x = 0, .y = 0 })) state.is_demo_open = true;
        }
    }

    if (is_save_config) {
        if (exe_dir) |dir| {
            config.trySave(dir);
        } else {
            std.log.err("Expected exe dir to exist when saving config", .{});
        }
    }

    c.igRender();
}
