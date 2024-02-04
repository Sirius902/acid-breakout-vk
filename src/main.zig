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
const Game = @import("game/game.zig").Game;
const DrawList = @import("game/game.zig").DrawList;
const Allocator = std.mem.Allocator;
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
    color: Vec4,

    const binding_description = vk.VertexInputBindingDescription{
        .binding = 0,
        .stride = @sizeOf(Vertex),
        .input_rate = .vertex,
    };

    const attribute_description = [_]vk.VertexInputAttributeDescription{
        .{
            .binding = 0,
            .location = 0,
            .format = .r32g32_sfloat,
            .offset = @offsetOf(Vertex, "pos"),
        },
        .{
            .binding = 0,
            .location = 1,
            .format = .r32g32b32a32_sfloat,
            .offset = @offsetOf(Vertex, "color"),
        },
    };
};

const Shading = enum(u32) {
    color = 0,
    rainbow = 1,
    rainbow_scroll = 2,
};

const PushConstants = extern struct {
    view: zlm.Mat4,
    viewport_size: zlm.Vec2,
    time: f32,
    shading: Shading,
};

const Config = struct {
    wait_for_vsync: bool = true,
    volume: f32 = 1,

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
        config.volume = std.math.clamp(config.volume, 0, 1);
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

    c.glfwWindowHint(c.GLFW_CLIENT_API, c.GLFW_NO_API);
    const window = c.glfwCreateWindow(
        @intCast(extent.width),
        @intCast(extent.height),
        app_name,
        null,
        null,
    ) orelse return error.WindowInitFailed;
    defer c.glfwDestroyWindow(window);

    const gc = try GraphicsContext.init(allocator, app_name, window);
    defer gc.deinit();

    var swapchain = try Swapchain.init(gc, allocator, extent, config.wait_for_vsync);
    defer swapchain.deinit();

    const push_contant_range = vk.PushConstantRange{
        .stage_flags = .{ .vertex_bit = true, .fragment_bit = true },
        .size = @sizeOf(PushConstants),
        .offset = 0,
    };

    const pipeline_layout = try gc.vkd.createPipelineLayout(gc.dev, &.{
        .flags = .{},
        .set_layout_count = 0,
        .p_set_layouts = undefined,
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

    const pipeline = try createPipeline(gc, pipeline_layout, render_pass, .triangle_list);
    defer gc.vkd.destroyPipeline(gc.dev, pipeline, null);

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

    var vertex_buffers = try allocator.alloc(?Buffer(Vertex), swapchain.swap_images.len);
    defer {
        for (vertex_buffers) |*vb_opt| if (vb_opt.*) |*vb| vb.deinit(gc);
        allocator.free(vertex_buffers);
    }
    @memset(vertex_buffers, null);

    var index_buffers = try allocator.alloc(?Buffer(u16), swapchain.swap_images.len);
    defer {
        for (index_buffers) |*ib_opt| if (ib_opt.*) |*ib| ib.deinit(gc);
        allocator.free(index_buffers);
    }
    @memset(index_buffers, null);

    var ac = try AudioContext.init(allocator);
    defer ac.deinit();

    ac.setGain(config.volume);
    try ac.cacheSound(&assets.ball_reflect);

    var game = try Game.init(vec2u(extent.width, extent.height), allocator);
    defer game.deinit();

    var draw_list = DrawList.init(allocator);
    defer draw_list.deinit();

    var is_demo_open = false;
    var is_config_open = true;
    var is_graphics_outdated = false;

    var frame_timer = std.time.Timer.start() catch @panic("Expected timer to be supported");
    while (c.glfwWindowShouldClose(window) == c.GLFW_FALSE) {
        var mxf: f64 = undefined;
        var myf: f64 = undefined;
        c.glfwGetCursorPos(window, &mxf, &myf);

        const mx: c_int = @intFromFloat(@round(mxf));
        const my: c_int = @intFromFloat(@round(myf));

        var ww: c_int = undefined;
        var wh: c_int = undefined;
        c.glfwGetWindowSize(window, &ww, &wh);
        const window_size = vec2(@floatFromInt(ww), @floatFromInt(wh));

        // TODO: Figure out what else needs to be done to work properly on high DPI displays.
        var fw: c_int = undefined;
        var fh: c_int = undefined;
        c.glfwGetFramebufferSize(window, &fw, &fh);

        const mouse_pos = if (mx >= 0 and mx < ww and my >= 0 and my < wh)
            vec2(@floatCast(mxf), @floatCast(myf)).mul(math.vec2Cast(f32, game.size)).div(window_size)
        else
            null;

        game.updateInput(mouse_pos);
        const tick_result = game.tick(frame_timer.lap());
        for (tick_result.sound_list) |hash| {
            try ac.playSound(hash);
        }

        // Don't present or resize swapchain while the window is minimized
        if (fw == 0 or fh == 0) {
            c.glfwPollEvents();
            continue;
        }

        ic.newFrame();

        if (is_demo_open) c.igShowDemoWindow(&is_demo_open);
        if (is_config_open) {
            if (c.igBegin(app_name, &is_config_open, c.ImGuiWindowFlags_None)) {
                defer c.igEnd();

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

                var is_save_config = false;
                if (c.igCheckbox("Wait for VSync", &config.wait_for_vsync)) {
                    is_graphics_outdated = true;
                    is_save_config = true;
                }

                if (c.igSliderFloat("Volume", &config.volume, 0, 1, "%.2f", 0)) {
                    ac.setGain(config.volume);
                    is_save_config = true;
                }

                if (c.igButton("Reset Volume", c.ImVec2{ .x = 0, .y = 0 })) {
                    config.volume = 1;
                    ac.setGain(config.volume);
                    is_save_config = true;
                }

                if (c.igButton("Play Sound", .{ .x = 0, .y = 0 })) {
                    ac.playSound(&assets.ball_reflect.hash) catch |err| std.log.err("Failed to play sound: {}", .{err});
                }

                if (is_save_config) {
                    if (exe_dir) |*dir| {
                        config.trySave(dir);
                    } else {
                        std.log.err("Expected exe dir to exist when saving config", .{});
                    }
                }

                if (c.igButton("Open Demo Window", .{ .x = 0, .y = 0 })) is_demo_open = true;
            }
        }

        ic.render();

        draw_list.clear();
        try game.draw(&draw_list);

        var draw_data = try executeDrawList(&draw_list, allocator);
        defer draw_data.deinit();
        const vertices = draw_data.rect_vertices.items;
        const indices = draw_data.rect_indices.items;

        // TODO: Store Rect vertex data and index data in the same buffer.
        const vertex_buffer_opt = &vertex_buffers[swapchain.image_index];
        if (vertex_buffer_opt.*) |*vb| {
            try vb.ensureTotalCapacity(gc, vertices.len);
        } else {
            vertex_buffer_opt.* = try Buffer(Vertex).init(gc, vertices.len, .{
                .usage = .{
                    .transfer_dst_bit = true,
                    .vertex_buffer_bit = true,
                },
                .sharing_mode = .exclusive,
            });
        }
        const vertex_buffer = &vertex_buffer_opt.*.?;
        try vertex_buffer.upload(gc, pool, vertices);

        const index_buffer_opt = &index_buffers[swapchain.image_index];
        if (index_buffer_opt.*) |*ib| {
            try ib.ensureTotalCapacity(gc, indices.len);
        } else {
            index_buffer_opt.* = try Buffer(u16).init(gc, indices.len, .{
                .usage = .{
                    .transfer_dst_bit = true,
                    .index_buffer_bit = true,
                },
                .sharing_mode = .exclusive,
            });
        }
        const index_buffer = &index_buffer_opt.*.?;
        try index_buffer.upload(gc, pool, indices);

        const cmdbuf = cmdbufs[swapchain.image_index];
        const current_image = try swapchain.acquireImage();
        try recordCommandBuffer(
            gc,
            &ic,
            &game,
            vertex_buffer,
            index_buffer,
            swapchain.extent,
            render_pass,
            pipeline,
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
        };

        pub fn init(gc: *const GraphicsContext, capacity: vk.DeviceSize, info: Info) !Self {
            const handle = try gc.vkd.createBuffer(gc.dev, &.{
                .size = capacity * @sizeOf(T),
                .usage = info.usage,
                .sharing_mode = info.sharing_mode,
            }, null);
            errdefer gc.vkd.destroyBuffer(gc.dev, handle, null);
            const mem_reqs = gc.vkd.getBufferMemoryRequirements(gc.dev, handle);
            const memory = try gc.allocate(mem_reqs, .{ .device_local_bit = true });
            errdefer gc.vkd.freeMemory(gc.dev, memory, null);
            try gc.vkd.bindBufferMemory(gc.dev, handle, memory, 0);

            return .{ .handle = handle, .memory = memory, .capacity = capacity, .len = 0, .info = info };
        }

        pub fn deinit(self: *Self, gc: *const GraphicsContext) void {
            gc.vkd.freeMemory(gc.dev, self.memory, null);
            gc.vkd.destroyBuffer(gc.dev, self.handle, null);
        }

        pub fn upload(
            self: *Self,
            gc: *const GraphicsContext,
            pool: vk.CommandPool,
            data: []const T,
        ) !void {
            std.debug.assert(self.capacity >= data.len);

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
                self.* = try Self.init(gc, capacity, self.info);
                old.deinit(gc);
            }
        }
    };
}

const DrawData = struct {
    rect_vertices: std.ArrayList(Vertex),
    rect_indices: std.ArrayList(u16),

    pub fn init(allocator: Allocator) DrawData {
        return .{
            .rect_vertices = std.ArrayList(Vertex).init(allocator),
            .rect_indices = std.ArrayList(u16).init(allocator),
        };
    }

    pub fn deinit(self: *DrawData) void {
        self.rect_vertices.deinit();
        self.rect_indices.deinit();
    }
};

fn executeDrawList(draw_list: *const DrawList, allocator: Allocator) !DrawData {
    var draw_data = DrawData.init(allocator);
    errdefer draw_data.deinit();

    // TODO: Use lines topology with separate pipeline.
    for (draw_list.paths.items) |path| {
        for (path.points) |point| {
            const point_size = Vec2.one.scale(2);
            const min = point.pos.sub(point_size.scale(0.5));
            const max = point.pos.add(point_size.scale(0.5));

            const rect_verts = [_]Vertex{
                .{ .pos = min, .color = vec4(1, 0, 0, 1) },
                .{ .pos = max, .color = vec4(0, 1, 0, 1) },
                .{ .pos = vec2(min.x, max.y), .color = vec4(0, 0, 1, 1) },
                .{ .pos = vec2(max.x, min.y), .color = vec4(0.25, 0, 1, 1) },
            };

            var rect_indices = [_]u16{ 0, 1, 2, 0, 3, 1 };
            for (&rect_indices) |*i| i.* += @intCast(draw_data.rect_vertices.items.len);

            try draw_data.rect_vertices.appendSlice(&rect_verts);
            try draw_data.rect_indices.appendSlice(&rect_indices);
        }
    }

    // TODO: Use points topology with separate pipeline.
    for (draw_list.points.items) |point| {
        const point_size = Vec2.one.scale(2);
        const min = point.pos.sub(point_size.scale(0.5));
        const max = point.pos.add(point_size.scale(0.5));

        const rect_verts = [_]Vertex{
            .{ .pos = min, .color = vec4(1, 0, 0, 1) },
            .{ .pos = max, .color = vec4(0, 1, 0, 1) },
            .{ .pos = vec2(min.x, max.y), .color = vec4(0, 0, 1, 1) },
            .{ .pos = vec2(max.x, min.y), .color = vec4(0.25, 0, 1, 1) },
        };

        var rect_indices = [_]u16{ 0, 1, 2, 0, 3, 1 };
        for (&rect_indices) |*i| i.* += @intCast(draw_data.rect_vertices.items.len);

        try draw_data.rect_vertices.appendSlice(&rect_verts);
        try draw_data.rect_indices.appendSlice(&rect_indices);
    }

    for (draw_list.rects.items) |rect| {
        const rect_verts = [_]Vertex{
            .{ .pos = rect.min, .color = vec4(1, 0, 0, 1) },
            .{ .pos = rect.max, .color = vec4(0, 1, 0, 1) },
            .{ .pos = vec2(rect.min.x, rect.max.y), .color = vec4(0, 0, 1, 1) },
            .{ .pos = vec2(rect.max.x, rect.min.y), .color = vec4(0.25, 0, 1, 1) },
        };

        var rect_indices = [_]u16{ 0, 1, 2, 0, 3, 1 };
        for (&rect_indices) |*i| i.* += @intCast(draw_data.rect_vertices.items.len);

        try draw_data.rect_vertices.appendSlice(&rect_verts);
        try draw_data.rect_indices.appendSlice(&rect_indices);
    }

    return draw_data;
}

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

fn recordCommandBuffer(
    gc: *const GraphicsContext,
    ic: *const ImGuiContext,
    game: *const Game,
    vertex_buffer: *const Buffer(Vertex),
    index_buffer: *const Buffer(u16),
    extent: vk.Extent2D,
    render_pass: vk.RenderPass,
    pipeline: vk.Pipeline,
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
    const view = zlm.Mat4.createOrthogonal(0, game_size.x, game_size.y, 0, 0, 100);
    var push_constants: PushConstants = .{
        .view = view,
        // TODO: Maintain game aspect ratio and use game size.
        .viewport_size = vec2(@floatFromInt(extent.width), @floatFromInt(extent.height)),
        .time = game.time,
        .shading = .rainbow_scroll,
    };

    gc.vkd.cmdBeginRenderPass(cmdbuf, &.{
        .render_pass = render_pass,
        .framebuffer = framebuffer,
        .render_area = render_area,
        .clear_value_count = 1,
        .p_clear_values = @as([*]const vk.ClearValue, @ptrCast(&clear)),
    }, .@"inline");

    gc.vkd.cmdBindPipeline(cmdbuf, .graphics, pipeline);
    const offsets = [_]vk.DeviceSize{0};
    gc.vkd.cmdBindVertexBuffers(cmdbuf, 0, 1, @ptrCast(&vertex_buffer.handle), &offsets);
    gc.vkd.cmdBindIndexBuffer(cmdbuf, index_buffer.handle, 0, .uint16);
    gc.vkd.cmdPushConstants(cmdbuf, pipeline_layout, .{ .vertex_bit = true, .fragment_bit = true }, 0, @sizeOf(PushConstants), @ptrCast(&push_constants));
    gc.vkd.cmdDrawIndexed(cmdbuf, @intCast(index_buffer.len), 1, 0, 0, 0);

    ic.drawTexture(cmdbuf);

    gc.vkd.cmdEndRenderPass(cmdbuf);
    try gc.vkd.endCommandBuffer(cmdbuf);
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
    gc: *const GraphicsContext,
    layout: vk.PipelineLayout,
    render_pass: vk.RenderPass,
    topology: vk.PrimitiveTopology,
) !vk.Pipeline {
    const vert = try gc.vkd.createShaderModule(gc.dev, &.{
        .code_size = shaders.main_vert.len,
        .p_code = @as([*]const u32, @ptrCast(&shaders.main_vert)),
    }, null);
    defer gc.vkd.destroyShaderModule(gc.dev, vert, null);

    const frag = try gc.vkd.createShaderModule(gc.dev, &.{
        .code_size = shaders.main_frag.len,
        .p_code = @as([*]const u32, @ptrCast(&shaders.main_frag)),
    }, null);
    defer gc.vkd.destroyShaderModule(gc.dev, frag, null);

    const pssci = [_]vk.PipelineShaderStageCreateInfo{
        .{
            .stage = .{ .vertex_bit = true },
            .module = vert,
            .p_name = "main",
        },
        .{
            .stage = .{ .fragment_bit = true },
            .module = frag,
            .p_name = "main",
        },
    };

    const pvisci = vk.PipelineVertexInputStateCreateInfo{
        .vertex_binding_description_count = 1,
        .p_vertex_binding_descriptions = @ptrCast(&Vertex.binding_description),
        .vertex_attribute_description_count = Vertex.attribute_description.len,
        .p_vertex_attribute_descriptions = &Vertex.attribute_description,
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
