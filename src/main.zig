const std = @import("std");
const c = @import("c.zig");
const vk = @import("vulkan");
const zlm = @import("zlm");
const assets = @import("assets");
const shaders = @import("shaders");
const math = @import("math.zig");
const GraphicsContext = @import("graphics_context.zig").GraphicsContext;
const Swapchain = @import("swapchain.zig").Swapchain;
const ImGuiContext = @import("imgui_context.zig").ImGuiContext;
const AudioContext = @import("audio_context.zig").AudioContext;
const InputContext = @import("InputContext.zig");
const Game = @import("game/game.zig").Game;
const DrawList = @import("game/game.zig").DrawList;
const Allocator = std.mem.Allocator;
const MemoryPoolExtra = std.heap.MemoryPoolExtra;
const Vec2 = zlm.Vec2;
const Vec3 = zlm.Vec3;
const Vec4 = zlm.Vec4;
const vec2 = zlm.vec2;
const vec3 = zlm.vec3;
const vec4 = zlm.vec4;
const vec2i = math.vec2i;
const vec2u = math.vec2u;

const app_name = "Acid Breakout";

const Vertex = struct {
    pos: Vec2,
    uv: Vec2,

    const binding = 0;

    const binding_description = vk.VertexInputBindingDescription{
        .binding = binding,
        .stride = @sizeOf(Vertex),
        .input_rate = .vertex,
    };

    const attribute_description = [_]vk.VertexInputAttributeDescription{
        .{
            .binding = binding,
            .location = 0,
            .format = .r32g32_sfloat,
            .offset = @offsetOf(Vertex, "pos"),
        },
        .{
            .binding = binding,
            .location = 1,
            .format = .r32g32_sfloat,
            .offset = @offsetOf(Vertex, "uv"),
        },
    };
};

const rect_verts = [_]Vertex{
    .{ .pos = Vec2.zero, .uv = Vec2.zero },
    .{ .pos = Vec2.one, .uv = Vec2.one },
    .{ .pos = vec2(0, 1), .uv = vec2(0, 1) },
    .{ .pos = vec2(1, 0), .uv = vec2(1, 0) },
};

const rect_indices = [_]u16{ 0, 1, 2, 0, 3, 1 };

const Shading = enum(u32) {
    color = 0,
    rainbow = 1,
    rainbow_scroll = 2,
};

const Instance = struct {
    model: zlm.Mat4,
    color: Vec4,
    shading: Shading,

    const binding = 1;

    const binding_description = vk.VertexInputBindingDescription{
        .binding = binding,
        .stride = @sizeOf(Instance),
        .input_rate = .instance,
    };

    const attribute_description = [_]vk.VertexInputAttributeDescription{
        .{
            .binding = binding,
            .location = 2,
            .format = .r32g32b32a32_sfloat,
            .offset = @offsetOf(Instance, "model") + 0 * @sizeOf(zlm.Vec4),
        },
        .{
            .binding = binding,
            .location = 3,
            .format = .r32g32b32a32_sfloat,
            .offset = @offsetOf(Instance, "model") + 1 * @sizeOf(zlm.Vec4),
        },
        .{
            .binding = binding,
            .location = 4,
            .format = .r32g32b32a32_sfloat,
            .offset = @offsetOf(Instance, "model") + 2 * @sizeOf(zlm.Vec4),
        },
        .{
            .binding = binding,
            .location = 5,
            .format = .r32g32b32a32_sfloat,
            .offset = @offsetOf(Instance, "model") + 3 * @sizeOf(zlm.Vec4),
        },
        .{
            .binding = binding,
            .location = 6,
            .format = .r32g32b32a32_sfloat,
            .offset = @offsetOf(Instance, "color"),
        },
        .{
            .binding = binding,
            .location = 7,
            .format = .r32_uint,
            .offset = @offsetOf(Instance, "shading"),
        },
    };
};

const PointVertex = struct {
    pos: Vec2,
    color: Vec4,
    shading: Shading,

    const binding = 0;

    const binding_description = vk.VertexInputBindingDescription{
        .binding = binding,
        .stride = @sizeOf(PointVertex),
        .input_rate = .vertex,
    };

    const attribute_description = [_]vk.VertexInputAttributeDescription{
        .{
            .binding = binding,
            .location = 0,
            .format = .r32g32_sfloat,
            .offset = @offsetOf(PointVertex, "pos"),
        },
        .{
            .binding = binding,
            .location = 1,
            .format = .r32g32b32a32_sfloat,
            .offset = @offsetOf(PointVertex, "color"),
        },
        .{
            .binding = binding,
            .location = 2,
            .format = .r32_uint,
            .offset = @offsetOf(PointVertex, "shading"),
        },
    };
};

const PushConstants = extern struct {
    view: zlm.Mat4,
    aspect: zlm.Vec2,
    viewport_size: zlm.Vec2,
    time: f32,
};

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

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){ .backing_allocator = std.heap.c_allocator };
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const exe_dir_path = std.fs.selfExeDirPathAlloc(allocator) catch |err| blk: {
        std.log.err("Failed to get exe dir path: {}", .{err});
        break :blk null;
    };
    defer if (exe_dir_path) |path| allocator.free(path);

    var exe_dir = if (exe_dir_path) |path| std.fs.openDirAbsolute(path, .{}) catch |err| blk: {
        std.log.err("Failed to open exe dir: {}", .{err});
        break :blk null;
    } else null;
    defer if (exe_dir) |*dir| dir.close();

    var config: Config = if (exe_dir) |*dir|
        Config.loadOrDefault(dir, allocator)
    else blk: {
        std.log.err("Expected exe dir path to exist when loading config", .{});
        break :blk .{};
    };

    if (c.glfwInit() != c.GLFW_TRUE) return error.GlfwInitFailed;
    defer c.glfwTerminate();

    if (c.glfwVulkanSupported() != c.GLFW_TRUE) {
        std.log.err("GLFW could not find libvulkan", .{});
        return error.NoVulkan;
    }

    _ = c.glfwSetErrorCallback(glfwErrorCallback);

    var extent = vk.Extent2D{ .width = 800, .height = 600 };

    // Synchronization is not required to access inputs on the thread that polls GLFW events.
    var input = InputContext.init();

    c.glfwWindowHint(c.GLFW_CLIENT_API, c.GLFW_NO_API);
    const window = c.glfwCreateWindow(
        @intCast(extent.width),
        @intCast(extent.height),
        app_name,
        null,
        null,
    ) orelse return error.WindowInitFailed;
    defer c.glfwDestroyWindow(window);

    _ = c.glfwSetWindowUserPointer(window, &input);
    _ = c.glfwSetCursorPosCallback(window, glfwCursorPosCallback);
    _ = c.glfwSetKeyCallback(window, glfwKeyCallback);

    const gc = try GraphicsContext.init(allocator, app_name, window);
    defer gc.deinit();

    var swapchain = try Swapchain.init(gc, allocator, extent, config.wait_for_vsync);
    defer swapchain.deinit();

    const descriptor_set_binding = vk.DescriptorSetLayoutBinding{
        .stage_flags = .{ .fragment_bit = true },
        .descriptor_type = .combined_image_sampler,
        .binding = 0,
        .descriptor_count = 1,
    };

    const descriptor_set_layout = try gc.vkd.createDescriptorSetLayout(gc.dev, &.{
        .binding_count = 1,
        .p_bindings = @ptrCast(&descriptor_set_binding),
    }, null);
    defer gc.vkd.destroyDescriptorSetLayout(gc.dev, descriptor_set_layout, null);

    const push_contant_range = vk.PushConstantRange{
        .stage_flags = .{ .vertex_bit = true, .fragment_bit = true },
        .size = @sizeOf(PushConstants),
        .offset = 0,
    };

    const pipeline_layout = try gc.vkd.createPipelineLayout(gc.dev, &.{
        .flags = .{},
        .set_layout_count = 1,
        .p_set_layouts = @ptrCast(&descriptor_set_layout),
        .push_constant_range_count = 1,
        .p_push_constant_ranges = @ptrCast(&push_contant_range),
    }, null);
    defer gc.vkd.destroyPipelineLayout(gc.dev, pipeline_layout, null);

    const render_pass = try createRenderPass(gc, swapchain);
    defer gc.vkd.destroyRenderPass(gc.dev, render_pass, null);

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

    const pipelines = try createPipelines(gc, pipeline_layout, render_pass);
    defer destroyPipelines(pipelines, gc);

    var framebuffers = try createFramebuffers(gc, allocator, render_pass, swapchain);
    defer destroyFramebuffers(gc, allocator, framebuffers);

    const pool = try gc.vkd.createCommandPool(gc.dev, &.{
        .queue_family_index = gc.graphics_queue.family,
        .flags = .{ .reset_command_buffer_bit = true },
    }, null);
    defer gc.vkd.destroyCommandPool(gc.dev, pool, null);

    var ic = try ImGuiContext.init(gc, &swapchain, allocator, render_pass, window, imgui_ini_path);
    defer ic.deinit();

    var cmdbufs = try createCommandBuffers(
        gc,
        pool,
        allocator,
        framebuffers,
    );
    defer destroyCommandBuffers(gc, pool, allocator, cmdbufs);

    var rect_vertex_buffer = try Buffer(Vertex).initWithCapacity(gc, rect_verts.len, .{
        .usage = .{
            .transfer_dst_bit = true,
            .vertex_buffer_bit = true,
        },
        .sharing_mode = .exclusive,
        .mem_flags = .{ .device_local_bit = true },
    });
    defer rect_vertex_buffer.deinit(gc);
    try rect_vertex_buffer.upload(gc, pool, &rect_verts);

    var rect_index_buffer = try Buffer(u16).initWithCapacity(gc, rect_indices.len, .{
        .usage = .{
            .transfer_dst_bit = true,
            .index_buffer_bit = true,
        },
        .sharing_mode = .exclusive,
        .mem_flags = .{ .device_local_bit = true },
    });
    defer rect_index_buffer.deinit(gc);
    try rect_index_buffer.upload(gc, pool, &rect_indices);

    const rect_instance_buffers = try allocator.alloc(Buffer(Instance), swapchain.swap_images.len);
    for (rect_instance_buffers) |*ib| ib.* = Buffer(Instance).init(.{
        .usage = .{ .vertex_buffer_bit = true },
        .sharing_mode = .exclusive,
        .mem_flags = .{ .host_visible_bit = true, .host_coherent_bit = true },
    });
    defer {
        for (rect_instance_buffers) |*b| b.deinit(gc);
        allocator.free(rect_instance_buffers);
    }

    const point_vertex_buffers = try allocator.alloc(Buffer(PointVertex), swapchain.swap_images.len);
    for (point_vertex_buffers) |*ib| ib.* = Buffer(PointVertex).init(.{
        .usage = .{ .vertex_buffer_bit = true },
        .sharing_mode = .exclusive,
        .mem_flags = .{ .host_visible_bit = true, .host_coherent_bit = true },
    });
    defer {
        for (point_vertex_buffers) |*b| b.deinit(gc);
        allocator.free(point_vertex_buffers);
    }

    // TODO: Put vertex and index data in the same buffer?
    const line_vertex_buffers = try allocator.alloc(Buffer(PointVertex), swapchain.swap_images.len);
    for (line_vertex_buffers) |*ib| ib.* = Buffer(PointVertex).init(.{
        .usage = .{ .vertex_buffer_bit = true },
        .sharing_mode = .exclusive,
        .mem_flags = .{ .host_visible_bit = true, .host_coherent_bit = true },
    });
    defer {
        for (line_vertex_buffers) |*b| b.deinit(gc);
        allocator.free(line_vertex_buffers);
    }

    const line_index_buffers = try allocator.alloc(Buffer(u32), swapchain.swap_images.len);
    for (line_index_buffers) |*ib| ib.* = Buffer(u32).init(.{
        .usage = .{ .index_buffer_bit = true },
        .sharing_mode = .exclusive,
        .mem_flags = .{ .host_visible_bit = true, .host_coherent_bit = true },
    });
    defer {
        for (line_index_buffers) |*b| b.deinit(gc);
        allocator.free(line_index_buffers);
    }

    const pool_sizes = [_]vk.DescriptorPoolSize{
        .{ .type = .combined_image_sampler, .descriptor_count = @intCast(swapchain.swap_images.len) },
    };

    const descriptor_pool = try gc.vkd.createDescriptorPool(gc.dev, &.{
        .flags = .{ .free_descriptor_set_bit = true },
        .max_sets = @intCast(swapchain.swap_images.len * pool_sizes.len),
        .pool_size_count = @intCast(pool_sizes.len),
        .p_pool_sizes = &pool_sizes,
    }, null);
    defer gc.vkd.destroyDescriptorPool(gc.dev, descriptor_pool, null);

    var mask_pool = try MemoryPoolExtra(std.DoublyLinkedList(MaskNode).Node, .{ .growable = false }).initPreheated(allocator, swapchain.swap_images.len);
    defer mask_pool.deinit();

    var masks = std.DoublyLinkedList(MaskNode){};
    defer while (masks.pop()) |node| {
        node.data.buffer.deinit(gc);
        node.data.mask.deinit(gc, descriptor_pool);
    };

    var ac = try AudioContext.init(allocator);
    defer ac.deinit();

    if (config.volume) |volume| ac.setListenerGain(volume);
    if (config.pitch_variance) |pv| ac.setSourcePitchVariance(pv);

    try ac.cacheSound(&assets.ball_reflect);
    try ac.cacheSound(&assets.ball_free);

    var game = try Game.init(vec2u(extent.width, extent.height), allocator);
    defer game.deinit();

    var draw_list = DrawList.init(allocator);
    defer draw_list.deinit();

    var is_demo_open = false;
    var is_graphics_outdated = false;
    var is_f1_down = false;

    var frame_timer = std.time.Timer.start() catch @panic("Expected timer to be supported");
    while (c.glfwWindowShouldClose(window) == c.GLFW_FALSE) {
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

        // Don't present or resize swapchain while the window is minimized
        if (fw == 0 or fh == 0) {
            c.glfwPollEvents();
            continue;
        }

        ic.newFrame();

        var is_save_config = false;

        const f1 = input.keyState(.f1).isDown();
        if (!is_f1_down and f1) {
            config.is_config_open = !config.is_config_open;
            is_save_config = true;
        }
        is_f1_down = f1;

        if (is_demo_open) c.igShowDemoWindow(&is_demo_open);
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
                    game.reset(vec2u(extent.width, extent.height));
                }

                if (c.igCheckbox("Wait for VSync", &config.wait_for_vsync)) {
                    is_graphics_outdated = true;
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

                if (c.igButton("Open Demo Window", .{ .x = 0, .y = 0 })) is_demo_open = true;
            }
        }

        if (is_save_config) {
            if (exe_dir) |*dir| {
                config.trySave(dir);
            } else {
                std.log.err("Expected exe dir to exist when saving config", .{});
            }
        }

        ic.render();

        draw_list.clear();
        try game.draw(&draw_list);

        var draw_data = try executeDrawList(&draw_list, allocator);
        defer draw_data.deinit();

        const current_image = try swapchain.acquireImage();

        const cmdbuf = cmdbufs[swapchain.image_index];
        const rect_instance_buffer = &rect_instance_buffers[swapchain.image_index];
        const masked_rects_start = draw_data.rects.items.len;
        const num_rects = masked_rects_start + draw_data.masked_rects.items.len;
        if (draw_data.rects.items.len > 0) {
            try rect_instance_buffer.ensureTotalCapacity(gc, num_rects);
            const gpu_instances = try rect_instance_buffer.map(gc);
            defer rect_instance_buffer.unmap(gc);
            @memcpy(gpu_instances, draw_data.rects.items);
            @memcpy(gpu_instances + masked_rects_start, draw_data.masked_rects.items);
        }
        rect_instance_buffer.len = num_rects;

        const point_vertex_buffer = &point_vertex_buffers[swapchain.image_index];
        if (draw_data.point_verts.items.len > 0) {
            try point_vertex_buffer.ensureTotalCapacity(gc, draw_data.point_verts.items.len);
            const gpu_points = try point_vertex_buffer.map(gc);
            defer point_vertex_buffer.unmap(gc);
            @memcpy(gpu_points, draw_data.point_verts.items);
        }
        point_vertex_buffer.len = draw_data.point_verts.items.len;

        const line_vertex_buffer = &line_vertex_buffers[swapchain.image_index];
        if (draw_data.line_verts.items.len > 0) {
            try line_vertex_buffer.ensureTotalCapacity(gc, draw_data.line_verts.items.len);
            const gpu_lines = try line_vertex_buffer.map(gc);
            defer line_vertex_buffer.unmap(gc);
            @memcpy(gpu_lines, draw_data.line_verts.items);
        }
        line_vertex_buffer.len = draw_data.line_verts.items.len;

        const line_index_buffer = &line_index_buffers[swapchain.image_index];
        if (draw_data.line_indices.items.len > 0) {
            try line_index_buffer.ensureTotalCapacity(gc, draw_data.line_indices.items.len);
            const gpu_indices = try line_index_buffer.map(gc);
            defer line_index_buffer.unmap(gc);
            @memcpy(gpu_indices, draw_data.line_indices.items);
        }
        line_index_buffer.len = draw_data.line_indices.items.len;

        {
            var node = masks.first;
            while (node) |n| {
                const next = n.next;
                defer node = next;

                n.data.frames_lived += 1;
                if (n.data.frames_lived >= swapchain.swap_images.len) {
                    masks.remove(n);
                    n.data.buffer.deinit(gc);
                    n.data.mask.deinit(gc, descriptor_pool);
                    mask_pool.destroy(n);
                }
            }
        }

        // TODO: Put in arena?
        var rect_masks = std.ArrayList(*const MaskNode).init(allocator);
        defer rect_masks.deinit();

        for (draw_data.rect_masks.items) |rect_mask| {
            var mask = Mask.init(gc, descriptor_set_layout, descriptor_pool, .{
                .width = rect_mask.width,
                .height = rect_mask.height,
            }) catch |err| {
                std.log.err("Failed to create mask: {}", .{err});
                return err;
            };
            errdefer mask.deinit(gc, descriptor_pool);

            var buffer = try Buffer(u8).initWithCapacity(gc, rect_mask.pixels.len, .{
                .usage = .{ .transfer_src_bit = true },
                .sharing_mode = .exclusive,
                .mem_flags = .{ .host_visible_bit = true, .host_coherent_bit = true },
            });
            errdefer buffer.deinit(gc);

            {
                const gpu_pixels = try buffer.map(gc);
                defer buffer.unmap(gc);
                @memcpy(gpu_pixels, rect_mask.pixels);
            }

            const node = try mask_pool.create();
            errdefer mask_pool.destroy(node);
            node.data = .{ .mask = mask, .buffer = buffer };

            masks.append(node);
            errdefer masks.remove(node);

            try rect_masks.append(&node.data);
        }

        try recordCommandBuffer(
            gc,
            &ic,
            &game,
            &rect_vertex_buffer,
            &rect_index_buffer,
            rect_instance_buffer,
            masked_rects_start,
            rect_masks.items,
            point_vertex_buffer,
            line_vertex_buffer,
            line_index_buffer,
            swapchain.extent,
            render_pass,
            pipelines,
            pipeline_layout,
            cmdbuf,
            framebuffers[swapchain.image_index],
        );

        const state = swapchain.present(cmdbuf, current_image) catch |err| switch (err) {
            error.OutOfDateKHR => Swapchain.PresentState.suboptimal,
            else => |narrow| return narrow,
        };

        if (state == .suboptimal or extent.width != @as(u32, @intCast(fw)) or extent.height != @as(u32, @intCast(fh)) or is_graphics_outdated) {
            extent.width = @intCast(fw);
            extent.height = @intCast(fh);
            try swapchain.recreate(extent, config.wait_for_vsync);

            destroyFramebuffers(gc, allocator, framebuffers);
            framebuffers = try createFramebuffers(gc, allocator, render_pass, swapchain);

            destroyCommandBuffers(gc, pool, allocator, cmdbufs);
            cmdbufs = try createCommandBuffers(
                gc,
                pool,
                allocator,
                framebuffers,
            );

            try ic.resize(&swapchain);

            is_graphics_outdated = false;
        }

        ic.postPresent();
        c.glfwPollEvents();
    }

    try swapchain.waitForAllFences();
    try gc.vkd.deviceWaitIdle(gc.dev);
}

fn glfwErrorCallback(error_code: c_int, description: [*c]const u8) callconv(.C) void {
    std.log.err("GLFW error {}: {s}", .{ error_code, description });
}

fn glfwCursorPosCallback(window: ?*c.GLFWwindow, x: f64, y: f64) callconv(.C) void {
    const input: *InputContext = @ptrCast(@alignCast(c.glfwGetWindowUserPointer(window).?));
    input.updateMouse(vec2(@floatCast(x), @floatCast(y)));
}

var glfw_scancode_cache: std.EnumMap(InputContext.Key, c_int) = .{};
fn glfwKeyCallback(window: ?*c.GLFWwindow, key: c_int, scancode: c_int, action: c_int, mods: c_int) callconv(.C) void {
    _ = key;
    _ = mods;

    const input_key: ?InputContext.Key = for (std.enums.values(InputContext.Key)) |k| {
        if (!glfw_scancode_cache.contains(k)) {
            const glfw_key = switch (k) {
                .escape => c.GLFW_KEY_ESCAPE,
                .f1 => c.GLFW_KEY_F1,
            };
            glfw_scancode_cache.put(k, c.glfwGetKeyScancode(glfw_key));
        }

        if (glfw_scancode_cache.getAssertContains(k) == scancode) break k;
    } else null;

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

fn Buffer(comptime T: type) type {
    return struct {
        handle: vk.Buffer,
        memory: vk.DeviceMemory,
        capacity: vk.DeviceSize,
        len: vk.DeviceSize,
        info: Info,

        const Self = @This();

        const Info = struct {
            usage: vk.BufferUsageFlags,
            sharing_mode: vk.SharingMode,
            mem_flags: vk.MemoryPropertyFlags,
        };

        pub fn init(info: Info) Self {
            return .{
                .handle = .null_handle,
                .memory = .null_handle,
                .capacity = 0,
                .len = 0,
                .info = info,
            };
        }

        pub fn initWithCapacity(gc: *const GraphicsContext, capacity: vk.DeviceSize, info: Info) !Self {
            const handle = try gc.vkd.createBuffer(gc.dev, &.{
                .size = capacity * @sizeOf(T),
                .usage = info.usage,
                .sharing_mode = info.sharing_mode,
            }, null);
            errdefer gc.vkd.destroyBuffer(gc.dev, handle, null);
            const mem_reqs = gc.vkd.getBufferMemoryRequirements(gc.dev, handle);
            const memory = try gc.allocate(mem_reqs, info.mem_flags);
            errdefer gc.vkd.freeMemory(gc.dev, memory, null);
            try gc.vkd.bindBufferMemory(gc.dev, handle, memory, 0);

            return .{ .handle = handle, .memory = memory, .capacity = capacity, .len = 0, .info = info };
        }

        pub fn deinit(self: *Self, gc: *const GraphicsContext) void {
            gc.vkd.freeMemory(gc.dev, self.memory, null);
            gc.vkd.destroyBuffer(gc.dev, self.handle, null);
        }

        pub fn map(self: *Self, gc: *const GraphicsContext) ![*]T {
            std.debug.assert(self.memory != .null_handle);
            const gpu_memory = try gc.vkd.mapMemory(gc.dev, self.memory, 0, vk.WHOLE_SIZE, .{});
            const data: [*]T = @ptrCast(@alignCast(gpu_memory));
            return data;
        }

        pub fn unmap(self: *Self, gc: *const GraphicsContext) void {
            gc.vkd.unmapMemory(gc.dev, self.memory);
        }

        pub fn upload(
            self: *Self,
            gc: *const GraphicsContext,
            pool: vk.CommandPool,
            data: []const T,
        ) !void {
            if (self.capacity < data.len) {
                try self.ensureTotalCapacity(gc, data.len);
            }

            const data_size = data.len * @sizeOf(T);
            const staging_buffer = try gc.vkd.createBuffer(gc.dev, &.{
                .size = data_size,
                .usage = .{ .transfer_src_bit = true },
                .sharing_mode = .exclusive,
            }, null);
            defer gc.vkd.destroyBuffer(gc.dev, staging_buffer, null);
            const mem_reqs = gc.vkd.getBufferMemoryRequirements(gc.dev, staging_buffer);
            const staging_memory = try gc.allocate(mem_reqs, .{ .host_visible_bit = true, .host_coherent_bit = true });
            defer gc.vkd.freeMemory(gc.dev, staging_memory, null);
            try gc.vkd.bindBufferMemory(gc.dev, staging_buffer, staging_memory, 0);

            {
                const gpu_memory = try gc.vkd.mapMemory(gc.dev, staging_memory, 0, vk.WHOLE_SIZE, .{});
                defer gc.vkd.unmapMemory(gc.dev, staging_memory);

                const gpu_data: [*]T = @ptrCast(@alignCast(gpu_memory));
                @memcpy(gpu_data, data);
            }

            try copyBuffer(gc, pool, self.handle, staging_buffer, data_size);
            self.len = data.len;
        }

        pub fn ensureTotalCapacity(self: *Self, gc: *const GraphicsContext, capacity: usize) !void {
            if (self.capacity < capacity) {
                var old = self.*;
                self.* = try Self.initWithCapacity(gc, capacity, self.info);
                old.deinit(gc);
            }
        }
    };
}

// TODO: Arena for draw data?
const DrawData = struct {
    rects: std.ArrayList(Instance),
    masked_rects: std.ArrayList(Instance),
    rect_masks: std.ArrayList(DrawList.Mask),
    point_verts: std.ArrayList(PointVertex),
    line_verts: std.ArrayList(PointVertex),
    line_indices: std.ArrayList(u32),

    pub fn init(allocator: Allocator) DrawData {
        return .{
            .rects = std.ArrayList(Instance).init(allocator),
            .masked_rects = std.ArrayList(Instance).init(allocator),
            .rect_masks = std.ArrayList(DrawList.Mask).init(allocator),
            .point_verts = std.ArrayList(PointVertex).init(allocator),
            .line_verts = std.ArrayList(PointVertex).init(allocator),
            .line_indices = std.ArrayList(u32).init(allocator),
        };
    }

    pub fn deinit(self: *DrawData) void {
        self.rects.deinit();
        self.masked_rects.deinit();
        self.rect_masks.deinit();
        self.point_verts.deinit();
        self.line_verts.deinit();
        self.line_indices.deinit();
    }
};

fn executeDrawList(draw_list: *const DrawList, allocator: Allocator) !DrawData {
    var draw_data = DrawData.init(allocator);
    errdefer draw_data.deinit();

    for (draw_list.rects.items) |rect| {
        const size = rect.size();
        const model = zlm.Mat4.createScale(size.x, size.y, 1)
            .mul(zlm.Mat4.createTranslation(vec3(rect.min.x, rect.min.y, 0)));

        var color: Vec4 = undefined;
        switch (rect.shading) {
            .color => |cl| color = cl,
            inline else => |alpha| color.w = alpha.a,
        }

        const shading: Shading = switch (rect.shading) {
            .color => .color,
            .rainbow => .rainbow,
            .rainbow_scroll => .rainbow_scroll,
        };

        const instance: Instance = .{
            .model = model,
            .color = color,
            .shading = shading,
        };

        if (rect.mask) |mask| {
            try draw_data.masked_rects.append(instance);
            try draw_data.rect_masks.append(mask);
        } else {
            try draw_data.rects.append(instance);
        }
    }

    for (draw_list.points.items) |point| {
        var color: Vec4 = undefined;
        switch (point.shading) {
            .color => |cl| color = cl,
            inline else => |alpha| color.w = alpha.a,
        }

        const shading: Shading = switch (point.shading) {
            .color => .color,
            .rainbow => .rainbow,
            .rainbow_scroll => .rainbow_scroll,
        };

        try draw_data.point_verts.append(.{
            .pos = point.pos,
            .color = color,
            .shading = shading,
        });
    }

    for (draw_list.paths.items) |path| {
        if (path.points.len == 0) continue;

        const path_start = draw_data.line_verts.items.len;
        for (path.points) |point| {
            var color: Vec4 = undefined;
            switch (point.shading) {
                .color => |cl| color = cl,
                inline else => |alpha| color.w = alpha.a,
            }

            const shading: Shading = switch (point.shading) {
                .color => .color,
                .rainbow => .rainbow,
                .rainbow_scroll => .rainbow_scroll,
            };

            try draw_data.line_verts.append(.{
                .pos = point.pos,
                .color = color,
                .shading = shading,
            });
        }

        if (path.points.len == 1) {
            try draw_data.line_indices.appendSlice(&[_]u32{ @intCast(path_start), @intCast(path_start) });
        } else {
            for (0..path.points.len - 1) |i| {
                try draw_data.line_indices.appendSlice(&[_]u32{ @intCast(path_start + i), @intCast(path_start + i + 1) });
            }
        }
    }

    return draw_data;
}

const Mask = struct {
    image: vk.Image,
    memory: vk.DeviceMemory,
    view: vk.ImageView,
    sampler: vk.Sampler,
    extent: vk.Extent2D,
    set: vk.DescriptorSet,

    pub fn init(
        gc: *const GraphicsContext,
        layout: vk.DescriptorSetLayout,
        descriptor_pool: vk.DescriptorPool,
        extent: vk.Extent2D,
    ) !Mask {
        var descriptor_set: vk.DescriptorSet = undefined;
        try gc.vkd.allocateDescriptorSets(gc.dev, &vk.DescriptorSetAllocateInfo{
            .descriptor_pool = descriptor_pool,
            .descriptor_set_count = 1,
            .p_set_layouts = @ptrCast(&layout),
        }, @ptrCast(&descriptor_set));
        errdefer gc.vkd.freeDescriptorSets(gc.dev, descriptor_pool, 1, @ptrCast(&descriptor_set)) catch {};

        const format: vk.Format = .r8_unorm;
        const image = try gc.vkd.createImage(gc.dev, &vk.ImageCreateInfo{
            .image_type = .@"2d",
            .format = format,
            .extent = .{ .width = extent.width, .height = extent.height, .depth = 1 },
            .mip_levels = 1,
            .array_layers = 1,
            .samples = .{ .@"1_bit" = true },
            .tiling = .optimal,
            .usage = .{ .color_attachment_bit = true, .transfer_dst_bit = true, .sampled_bit = true },
            .sharing_mode = .exclusive,
            .initial_layout = .undefined,
        }, null);
        errdefer gc.vkd.destroyImage(gc.dev, image, null);

        const mem_reqs = gc.vkd.getImageMemoryRequirements(gc.dev, image);
        const memory = try gc.allocate(mem_reqs, .{ .device_local_bit = true });
        errdefer gc.vkd.freeMemory(gc.dev, memory, null);

        try gc.vkd.bindImageMemory(gc.dev, image, memory, 0);

        const view = try gc.vkd.createImageView(gc.dev, &.{
            .image = image,
            .view_type = .@"2d",
            .format = format,
            .components = .{ .r = .identity, .g = .identity, .b = .identity, .a = .identity },
            .subresource_range = .{
                .aspect_mask = .{ .color_bit = true },
                .base_mip_level = 0,
                .level_count = 1,
                .base_array_layer = 0,
                .layer_count = 1,
            },
        }, null);
        errdefer gc.vkd.destroyImageView(gc.dev, view, null);

        const sampler = try gc.vkd.createSampler(gc.dev, &vk.SamplerCreateInfo{
            .mag_filter = .nearest,
            .min_filter = .nearest,
            .address_mode_u = .repeat,
            .address_mode_v = .repeat,
            .address_mode_w = .repeat,
            .anisotropy_enable = vk.FALSE,
            .max_anisotropy = undefined,
            .border_color = .float_opaque_white,
            .unnormalized_coordinates = vk.FALSE,
            .compare_enable = vk.FALSE,
            .compare_op = .always,
            .mipmap_mode = .linear,
            .mip_lod_bias = 0,
            .min_lod = 0,
            .max_lod = 0,
        }, null);
        errdefer gc.vkd.destroySampler(gc.dev, sampler, null);

        const image_info = vk.DescriptorImageInfo{
            .image_layout = .shader_read_only_optimal,
            .image_view = view,
            .sampler = sampler,
        };
        const descriptor_write = vk.WriteDescriptorSet{
            .dst_set = descriptor_set,
            .dst_binding = 0,
            .dst_array_element = 0,
            .descriptor_type = .combined_image_sampler,
            .descriptor_count = 1,
            .p_buffer_info = undefined,
            .p_texel_buffer_view = undefined,
            .p_image_info = @ptrCast(&image_info),
        };
        gc.vkd.updateDescriptorSets(gc.dev, 1, @ptrCast(&descriptor_write), 0, null);

        return .{
            .image = image,
            .memory = memory,
            .view = view,
            .sampler = sampler,
            .set = descriptor_set,
            .extent = extent,
        };
    }

    pub fn deinit(self: *Mask, gc: *const GraphicsContext, pool: vk.DescriptorPool) void {
        gc.vkd.freeDescriptorSets(gc.dev, pool, 1, @ptrCast(&self.set)) catch {};
        gc.vkd.destroySampler(gc.dev, self.sampler, null);
        gc.vkd.destroyImageView(gc.dev, self.view, null);
        gc.vkd.destroyImage(gc.dev, self.image, null);
        gc.vkd.freeMemory(gc.dev, self.memory, null);
    }

    pub fn recordUpload(self: *const Mask, gc: *const GraphicsContext, cmdbuf: vk.CommandBuffer, buffer: vk.Buffer) void {
        const undefined_to_transfer_barrier = vk.ImageMemoryBarrier{
            .src_access_mask = .{},
            .dst_access_mask = .{},
            .image = self.image,
            .old_layout = .undefined,
            .new_layout = .transfer_dst_optimal,
            .src_queue_family_index = gc.graphics_queue.family,
            .dst_queue_family_index = gc.graphics_queue.family,
            .subresource_range = .{
                .aspect_mask = .{ .color_bit = true },
                .base_mip_level = 0,
                .level_count = 1,
                .base_array_layer = 0,
                .layer_count = 1,
            },
        };
        gc.vkd.cmdPipelineBarrier(cmdbuf, .{ .top_of_pipe_bit = true }, .{ .transfer_bit = true }, .{}, 0, null, 0, null, 1, @ptrCast(&undefined_to_transfer_barrier));

        const region = vk.BufferImageCopy{
            .buffer_offset = 0,
            .buffer_row_length = 0,
            .buffer_image_height = 0,
            .image_offset = .{ .x = 0, .y = 0, .z = 0 },
            .image_extent = .{ .width = self.extent.width, .height = self.extent.height, .depth = 1 },
            .image_subresource = .{
                .aspect_mask = .{ .color_bit = true },
                .mip_level = 0,
                .base_array_layer = 0,
                .layer_count = 1,
            },
        };
        gc.vkd.cmdCopyBufferToImage(cmdbuf, buffer, self.image, .transfer_dst_optimal, 1, @ptrCast(&region));

        const transfer_to_shader_barrier = vk.ImageMemoryBarrier{
            .src_access_mask = .{},
            .dst_access_mask = .{},
            .image = self.image,
            .old_layout = .transfer_dst_optimal,
            .new_layout = .shader_read_only_optimal,
            .src_queue_family_index = gc.graphics_queue.family,
            .dst_queue_family_index = gc.graphics_queue.family,
            .subresource_range = .{
                .aspect_mask = .{ .color_bit = true },
                .base_mip_level = 0,
                .level_count = 1,
                .base_array_layer = 0,
                .layer_count = 1,
            },
        };
        gc.vkd.cmdPipelineBarrier(cmdbuf, vk.PipelineStageFlags{ .transfer_bit = true }, .{ .fragment_shader_bit = true }, .{}, 0, null, 0, null, 1, @ptrCast(&transfer_to_shader_barrier));
    }
};

fn copyBuffer(gc: *const GraphicsContext, pool: vk.CommandPool, dst: vk.Buffer, src: vk.Buffer, size: vk.DeviceSize) !void {
    var cmdbuf: vk.CommandBuffer = undefined;
    try gc.vkd.allocateCommandBuffers(gc.dev, &.{
        .command_pool = pool,
        .level = .primary,
        .command_buffer_count = 1,
    }, @ptrCast(&cmdbuf));
    defer gc.vkd.freeCommandBuffers(gc.dev, pool, 1, @ptrCast(&cmdbuf));

    try gc.vkd.beginCommandBuffer(cmdbuf, &.{
        .flags = .{ .one_time_submit_bit = true },
    });

    const region = vk.BufferCopy{
        .src_offset = 0,
        .dst_offset = 0,
        .size = size,
    };
    gc.vkd.cmdCopyBuffer(cmdbuf, src, dst, 1, @ptrCast(&region));

    try gc.vkd.endCommandBuffer(cmdbuf);

    const si = vk.SubmitInfo{
        .command_buffer_count = 1,
        .p_command_buffers = @ptrCast(&cmdbuf),
        .p_wait_dst_stage_mask = undefined,
    };
    try gc.vkd.queueSubmit(gc.graphics_queue.handle, 1, @ptrCast(&si), .null_handle);
    try gc.vkd.queueWaitIdle(gc.graphics_queue.handle);
}

fn createCommandBuffers(
    gc: *const GraphicsContext,
    pool: vk.CommandPool,
    allocator: Allocator,
    framebuffers: []vk.Framebuffer,
) ![]vk.CommandBuffer {
    const cmdbufs = try allocator.alloc(vk.CommandBuffer, framebuffers.len);
    errdefer allocator.free(cmdbufs);

    try gc.vkd.allocateCommandBuffers(gc.dev, &.{
        .command_pool = pool,
        .level = .primary,
        .command_buffer_count = @intCast(cmdbufs.len),
    }, cmdbufs.ptr);
    errdefer gc.vkd.freeCommandBuffers(gc.dev, pool, @truncate(cmdbufs.len), cmdbufs.ptr);

    return cmdbufs;
}

fn destroyCommandBuffers(gc: *const GraphicsContext, pool: vk.CommandPool, allocator: Allocator, cmdbufs: []vk.CommandBuffer) void {
    gc.vkd.freeCommandBuffers(gc.dev, pool, @truncate(cmdbufs.len), cmdbufs.ptr);
    allocator.free(cmdbufs);
}

const MaskNode = struct {
    mask: Mask,
    buffer: Buffer(u8),
    frames_lived: usize = 0,
};

fn recordCommandBuffer(
    gc: *const GraphicsContext,
    ic: *const ImGuiContext,
    game: *const Game,
    rect_vertex_buffer: *const Buffer(Vertex),
    rect_index_buffer: *const Buffer(u16),
    rect_instance_buffer: *const Buffer(Instance),
    masked_rects_start: usize,
    rect_masks: []const *const MaskNode,
    point_vertex_buffer: *const Buffer(PointVertex),
    line_vertex_buffer: *const Buffer(PointVertex),
    line_index_buffer: *const Buffer(u32),
    extent: vk.Extent2D,
    render_pass: vk.RenderPass,
    pipelines: Pipelines,
    pipeline_layout: vk.PipelineLayout,
    cmdbuf: vk.CommandBuffer,
    framebuffer: vk.Framebuffer,
) !void {
    const clear = vk.ClearValue{
        .color = .{ .float_32 = .{ 0, 0, 0, 1 } },
    };

    const viewport = vk.Viewport{
        .x = 0,
        .y = 0,
        .width = @as(f32, @floatFromInt(extent.width)),
        .height = @as(f32, @floatFromInt(extent.height)),
        .min_depth = 0,
        .max_depth = 1,
    };

    const scissor = vk.Rect2D{
        .offset = .{ .x = 0, .y = 0 },
        .extent = extent,
    };

    try gc.vkd.resetCommandBuffer(cmdbuf, .{});
    try gc.vkd.beginCommandBuffer(cmdbuf, &.{});

    for (rect_masks) |rect_mask| {
        rect_mask.mask.recordUpload(gc, cmdbuf, rect_mask.buffer.handle);
    }

    gc.vkd.cmdSetViewport(cmdbuf, 0, 1, @ptrCast(&viewport));
    gc.vkd.cmdSetScissor(cmdbuf, 0, 1, @ptrCast(&scissor));

    // This needs to be a separate definition - see https://github.com/ziglang/zig/issues/7627.
    const render_area = vk.Rect2D{
        .offset = .{ .x = 0, .y = 0 },
        .extent = extent,
    };

    try ic.renderDrawDataToTexture(cmdbuf);

    const game_size = math.vec2Cast(f32, game.size);
    // Invert y-axis since zlm assumes OpenGL axes, but Vulkan's y-axis is the opposite direction.
    const view = zlm.Mat4.createOrthogonal(0, game_size.x, game_size.y, 0, 0, 1);

    const aspect_ratio = (viewport.width / game_size.x) / (viewport.height / game_size.y);
    const aspect = if (viewport.width >= viewport.height)
        vec2(1.0 / aspect_ratio, 1)
    else
        vec2(1, aspect_ratio);

    const push_constants: PushConstants = .{
        .view = view.mul(zlm.Mat4.createScale(aspect.x, aspect.y, 1)),
        .aspect = aspect,
        .viewport_size = vec2(@floatFromInt(extent.width), @floatFromInt(extent.height)),
        .time = game.time,
    };
    gc.vkd.cmdPushConstants(cmdbuf, pipeline_layout, .{ .vertex_bit = true, .fragment_bit = true }, 0, @sizeOf(PushConstants), @ptrCast(&push_constants));

    gc.vkd.cmdBeginRenderPass(cmdbuf, &.{
        .render_pass = render_pass,
        .framebuffer = framebuffer,
        .render_area = render_area,
        .clear_value_count = 1,
        .p_clear_values = @as([*]const vk.ClearValue, @ptrCast(&clear)),
    }, .@"inline");

    if (line_vertex_buffer.handle != .null_handle) {
        const line_offsets = [_]vk.DeviceSize{0};

        gc.vkd.cmdBindPipeline(cmdbuf, .graphics, pipelines.line);
        gc.vkd.cmdBindVertexBuffers(cmdbuf, 0, 1, @ptrCast(&line_vertex_buffer.handle), &line_offsets);
        gc.vkd.cmdBindIndexBuffer(cmdbuf, line_index_buffer.handle, 0, .uint32);
        gc.vkd.cmdDrawIndexed(cmdbuf, @intCast(line_index_buffer.len), 1, 0, 0, 0);
    }

    if (point_vertex_buffer.handle != .null_handle) {
        const point_offsets = [_]vk.DeviceSize{0};

        gc.vkd.cmdBindPipeline(cmdbuf, .graphics, pipelines.point);
        gc.vkd.cmdBindVertexBuffers(cmdbuf, 0, 1, @ptrCast(&point_vertex_buffer.handle), &point_offsets);
        gc.vkd.cmdDraw(cmdbuf, @intCast(point_vertex_buffer.len), 1, 0, 0);
    }

    if (rect_instance_buffer.handle != .null_handle) {
        const rect_offsets = [_]vk.DeviceSize{ 0, 0 };
        const rect_vertex_buffers = [_]vk.Buffer{ rect_vertex_buffer.handle, rect_instance_buffer.handle };

        gc.vkd.cmdBindPipeline(cmdbuf, .graphics, pipelines.rect);
        gc.vkd.cmdBindVertexBuffers(cmdbuf, 0, rect_vertex_buffers.len, &rect_vertex_buffers, &rect_offsets);
        gc.vkd.cmdBindIndexBuffer(cmdbuf, rect_index_buffer.handle, 0, .uint16);

        gc.vkd.cmdDrawIndexed(cmdbuf, @intCast(rect_index_buffer.len), @intCast(rect_instance_buffer.len - masked_rects_start), 0, 0, 0);

        gc.vkd.cmdBindPipeline(cmdbuf, .graphics, pipelines.mask_rect);
        for (masked_rects_start..rect_instance_buffer.len, rect_masks) |i, rect_mask| {
            gc.vkd.cmdBindDescriptorSets(cmdbuf, .graphics, pipeline_layout, 0, 1, @ptrCast(&rect_mask.mask.set), 0, null);
            gc.vkd.cmdDrawIndexed(cmdbuf, @intCast(rect_index_buffer.len), 1, 0, 0, @intCast(i));
        }
    }

    ic.drawTexture(cmdbuf);

    gc.vkd.cmdEndRenderPass(cmdbuf);
    try gc.vkd.endCommandBuffer(cmdbuf);
}

const Pipelines = struct {
    rect: vk.Pipeline,
    point: vk.Pipeline,
    line: vk.Pipeline,
    mask_rect: vk.Pipeline,
};

fn createPipelines(gc: *const GraphicsContext, layout: vk.PipelineLayout, render_pass: vk.RenderPass) !Pipelines {
    const rect_vert = try gc.vkd.createShaderModule(gc.dev, &.{
        .code_size = shaders.rect_vert.len,
        .p_code = @as([*]const u32, @ptrCast(&shaders.rect_vert)),
    }, null);
    defer gc.vkd.destroyShaderModule(gc.dev, rect_vert, null);

    const point_vert = try gc.vkd.createShaderModule(gc.dev, &.{
        .code_size = shaders.point_vert.len,
        .p_code = @as([*]const u32, @ptrCast(&shaders.point_vert)),
    }, null);
    defer gc.vkd.destroyShaderModule(gc.dev, point_vert, null);

    const line_vert = try gc.vkd.createShaderModule(gc.dev, &.{
        .code_size = shaders.line_vert.len,
        .p_code = @as([*]const u32, @ptrCast(&shaders.line_vert)),
    }, null);
    defer gc.vkd.destroyShaderModule(gc.dev, line_vert, null);

    const frag = try gc.vkd.createShaderModule(gc.dev, &.{
        .code_size = shaders.main_frag.len,
        .p_code = @as([*]const u32, @ptrCast(&shaders.main_frag)),
    }, null);
    defer gc.vkd.destroyShaderModule(gc.dev, frag, null);

    const rect = try createPipeline(Vertex, Instance, gc, layout, render_pass, rect_vert, frag, .triangle_list);
    errdefer gc.vkd.destroyPipeline(gc.dev, rect, null);

    const point = try createPipeline(PointVertex, null, gc, layout, render_pass, point_vert, frag, .point_list);
    errdefer gc.vkd.destroyPipeline(gc.dev, point, null);

    const line = try createPipeline(PointVertex, null, gc, layout, render_pass, line_vert, frag, .line_list);
    errdefer gc.vkd.destroyPipeline(gc.dev, line, null);

    const mask_frag = try gc.vkd.createShaderModule(gc.dev, &.{
        .code_size = shaders.mask_frag.len,
        .p_code = @as([*]const u32, @ptrCast(&shaders.mask_frag)),
    }, null);
    defer gc.vkd.destroyShaderModule(gc.dev, mask_frag, null);

    const mask_rect = try createPipeline(Vertex, Instance, gc, layout, render_pass, rect_vert, mask_frag, .triangle_list);
    errdefer gc.vkd.destroyPipeline(gc.dev, mask_rect, null);

    return .{ .rect = rect, .point = point, .line = line, .mask_rect = mask_rect };
}

fn destroyPipelines(pipelines: Pipelines, gc: *const GraphicsContext) void {
    gc.vkd.destroyPipeline(gc.dev, pipelines.rect, null);
    gc.vkd.destroyPipeline(gc.dev, pipelines.point, null);
    gc.vkd.destroyPipeline(gc.dev, pipelines.line, null);
    gc.vkd.destroyPipeline(gc.dev, pipelines.mask_rect, null);
}

fn createFramebuffers(gc: *const GraphicsContext, allocator: Allocator, render_pass: vk.RenderPass, swapchain: Swapchain) ![]vk.Framebuffer {
    const framebuffers = try allocator.alloc(vk.Framebuffer, swapchain.swap_images.len);
    errdefer allocator.free(framebuffers);

    var i: usize = 0;
    errdefer for (framebuffers[0..i]) |fb| gc.vkd.destroyFramebuffer(gc.dev, fb, null);

    for (framebuffers) |*fb| {
        fb.* = try gc.vkd.createFramebuffer(gc.dev, &.{
            .render_pass = render_pass,
            .attachment_count = 1,
            .p_attachments = @as([*]const vk.ImageView, @ptrCast(&swapchain.swap_images[i].view)),
            .width = swapchain.extent.width,
            .height = swapchain.extent.height,
            .layers = 1,
        }, null);
        i += 1;
    }

    return framebuffers;
}

fn destroyFramebuffers(gc: *const GraphicsContext, allocator: Allocator, framebuffers: []const vk.Framebuffer) void {
    for (framebuffers) |fb| gc.vkd.destroyFramebuffer(gc.dev, fb, null);
    allocator.free(framebuffers);
}

fn createRenderPass(gc: *const GraphicsContext, swapchain: Swapchain) !vk.RenderPass {
    const color_attachment = vk.AttachmentDescription{
        .format = swapchain.surface_format.format,
        .samples = .{ .@"1_bit" = true },
        .load_op = .clear,
        .store_op = .store,
        .stencil_load_op = .dont_care,
        .stencil_store_op = .dont_care,
        .initial_layout = .undefined,
        .final_layout = .present_src_khr,
    };

    const color_attachment_ref = vk.AttachmentReference{
        .attachment = 0,
        .layout = .color_attachment_optimal,
    };

    const subpass = vk.SubpassDescription{
        .pipeline_bind_point = .graphics,
        .color_attachment_count = 1,
        .p_color_attachments = @ptrCast(&color_attachment_ref),
    };

    // Wait for ImGui to finish rendering to texture before running fragment shader.
    const imgui_dependency = vk.SubpassDependency{
        .src_subpass = vk.SUBPASS_EXTERNAL,
        .dst_subpass = 0,
        .src_stage_mask = .{ .color_attachment_output_bit = true },
        .dst_stage_mask = .{ .fragment_shader_bit = true },
        .src_access_mask = .{ .color_attachment_write_bit = true },
        .dst_access_mask = .{ .shader_read_bit = true },
    };

    return try gc.vkd.createRenderPass(gc.dev, &.{
        .attachment_count = 1,
        .p_attachments = @as([*]const vk.AttachmentDescription, @ptrCast(&color_attachment)),
        .subpass_count = 1,
        .p_subpasses = @as([*]const vk.SubpassDescription, @ptrCast(&subpass)),
        .dependency_count = 1,
        .p_dependencies = @as([*]const vk.SubpassDependency, @ptrCast(&imgui_dependency)),
    }, null);
}

fn createPipeline(
    comptime Vert: type,
    comptime Inst: ?type,
    gc: *const GraphicsContext,
    layout: vk.PipelineLayout,
    render_pass: vk.RenderPass,
    vertex_shader: vk.ShaderModule,
    fragment_shader: vk.ShaderModule,
    topology: vk.PrimitiveTopology,
) !vk.Pipeline {
    const pssci = [_]vk.PipelineShaderStageCreateInfo{
        .{
            .stage = .{ .vertex_bit = true },
            .module = vertex_shader,
            .p_name = "main",
        },
        .{
            .stage = .{ .fragment_bit = true },
            .module = fragment_shader,
            .p_name = "main",
        },
    };

    const vertex_bindings = if (Inst) |I|
        [_]vk.VertexInputBindingDescription{
            Vert.binding_description,
            I.binding_description,
        }
    else
        [_]vk.VertexInputBindingDescription{Vert.binding_description};

    const attribute_descriptions = if (Inst) |I|
        Vert.attribute_description ++ I.attribute_description
    else
        Vert.attribute_description;

    const pvisci = vk.PipelineVertexInputStateCreateInfo{
        .vertex_binding_description_count = vertex_bindings.len,
        .p_vertex_binding_descriptions = &vertex_bindings,
        .vertex_attribute_description_count = attribute_descriptions.len,
        .p_vertex_attribute_descriptions = &attribute_descriptions,
    };

    const piasci = vk.PipelineInputAssemblyStateCreateInfo{
        .topology = topology,
        .primitive_restart_enable = vk.FALSE,
    };

    const pvsci = vk.PipelineViewportStateCreateInfo{
        .viewport_count = 1,
        .p_viewports = undefined, // set in createCommandBuffers with cmdSetViewport
        .scissor_count = 1,
        .p_scissors = undefined, // set in createCommandBuffers with cmdSetScissor
    };

    const prsci = vk.PipelineRasterizationStateCreateInfo{
        .depth_clamp_enable = vk.FALSE,
        .rasterizer_discard_enable = vk.FALSE,
        .polygon_mode = .fill,
        .cull_mode = .{ .back_bit = true },
        .front_face = .counter_clockwise,
        .depth_bias_enable = vk.FALSE,
        .depth_bias_constant_factor = 0,
        .depth_bias_clamp = 0,
        .depth_bias_slope_factor = 0,
        .line_width = 1,
    };

    const pmsci = vk.PipelineMultisampleStateCreateInfo{
        .rasterization_samples = .{ .@"1_bit" = true },
        .sample_shading_enable = vk.FALSE,
        .min_sample_shading = 1,
        .alpha_to_coverage_enable = vk.FALSE,
        .alpha_to_one_enable = vk.FALSE,
    };

    const pcbas = vk.PipelineColorBlendAttachmentState{
        .blend_enable = vk.TRUE,
        .src_color_blend_factor = .src_alpha,
        .dst_color_blend_factor = .one_minus_src_alpha,
        .color_blend_op = .add,
        .src_alpha_blend_factor = .src_alpha,
        .dst_alpha_blend_factor = .one_minus_src_alpha,
        .alpha_blend_op = .subtract,
        .color_write_mask = .{ .r_bit = true, .g_bit = true, .b_bit = true, .a_bit = true },
    };

    const pcbsci = vk.PipelineColorBlendStateCreateInfo{
        .logic_op_enable = vk.FALSE,
        .logic_op = .copy,
        .attachment_count = 1,
        .p_attachments = @ptrCast(&pcbas),
        .blend_constants = [_]f32{ 0, 0, 0, 0 },
    };

    const dynstate = [_]vk.DynamicState{ .viewport, .scissor };
    const pdsci = vk.PipelineDynamicStateCreateInfo{
        .flags = .{},
        .dynamic_state_count = dynstate.len,
        .p_dynamic_states = &dynstate,
    };

    const gpci = vk.GraphicsPipelineCreateInfo{
        .flags = .{},
        .stage_count = @intCast(pssci.len),
        .p_stages = &pssci,
        .p_vertex_input_state = &pvisci,
        .p_input_assembly_state = &piasci,
        .p_tessellation_state = null,
        .p_viewport_state = &pvsci,
        .p_rasterization_state = &prsci,
        .p_multisample_state = &pmsci,
        .p_depth_stencil_state = null,
        .p_color_blend_state = &pcbsci,
        .p_dynamic_state = &pdsci,
        .layout = layout,
        .render_pass = render_pass,
        .subpass = 0,
        .base_pipeline_handle = .null_handle,
        .base_pipeline_index = -1,
    };

    var pipeline: vk.Pipeline = undefined;
    _ = try gc.vkd.createGraphicsPipelines(
        gc.dev,
        .null_handle,
        1,
        @ptrCast(&gpci),
        null,
        @ptrCast(&pipeline),
    );
    return pipeline;
}
