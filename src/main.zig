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
const vec2 = zlm.vec2;
const vec3 = zlm.vec3;
const vec2i = math.vec2i;
const vec2u = math.vec2u;

const app_name = "Acid Breakout";

const Vertex = struct {
    pos: Vec2,
    // TODO: Add alpha.
    color: Vec3,

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
            .format = .r32g32b32_sfloat,
            .offset = @offsetOf(Vertex, "color"),
        },
    };
};

var is_demo_open = false;
var is_config_open = true;

var graphics_outdated = false;
var wait_for_vsync = true;

pub fn main() !void {
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

    var gpa = std.heap.GeneralPurposeAllocator(.{}){ .backing_allocator = std.heap.c_allocator };
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const gc = try GraphicsContext.init(allocator, app_name, window);
    defer gc.deinit();

    var swapchain = try Swapchain.init(gc, allocator, extent, wait_for_vsync);
    defer swapchain.deinit();

    const pipeline_layout = try gc.vkd.createPipelineLayout(gc.dev, &.{
        .flags = .{},
        .set_layout_count = 0,
        .p_set_layouts = undefined,
        .push_constant_range_count = 0,
        .p_push_constant_ranges = undefined,
    }, null);
    defer gc.vkd.destroyPipelineLayout(gc.dev, pipeline_layout, null);

    const render_pass = try createRenderPass(gc, swapchain);
    defer gc.vkd.destroyRenderPass(gc.dev, render_pass, null);

    const imgui_ini_path = blk: {
        const exe_dir = try std.fs.selfExeDirPathAlloc(allocator);
        defer allocator.free(exe_dir);

        break :blk try std.fs.path.joinZ(
            allocator,
            &[_][]const u8{ exe_dir, "imgui.ini" },
        );
    };
    defer allocator.free(imgui_ini_path);

    const pipeline = try createPipeline(gc, pipeline_layout, render_pass);
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

    var vertex_buffers = try allocator.alloc(?Buffer, swapchain.swap_images.len);
    defer {
        for (vertex_buffers) |*vb_opt| if (vb_opt.*) |*vb| vb.deinit(gc);
        allocator.free(vertex_buffers);
    }
    @memset(vertex_buffers, null);

    var ac = try AudioContext.init(allocator);
    defer ac.deinit();

    try ac.cacheSound(&assets.ball_reflect);

    var game = try Game.init(vec2u(extent.width, extent.height), allocator);
    defer game.deinit();

    var draw_list = DrawList.init(allocator);
    defer draw_list.deinit();

    var frame_timer = std.time.Timer.start() catch @panic("Expected timer to be supported");
    while (c.glfwWindowShouldClose(window) == c.GLFW_FALSE) {
        var mxf: f64 = undefined;
        var myf: f64 = undefined;
        c.glfwGetCursorPos(window, &mxf, &myf);

        // TODO: Scale mouse position based on ratio of framebuffer size and window size.
        const mx: c_int = @intFromFloat(@round(mxf));
        const my: c_int = @intFromFloat(@round(myf));

        var ww: c_int = undefined;
        var wh: c_int = undefined;
        c.glfwGetWindowSize(window, &ww, &wh);

        var fw: c_int = undefined;
        var fh: c_int = undefined;
        c.glfwGetFramebufferSize(window, &fw, &fh);

        // TODO: Supply mouse position in game units instead of window units.
        const mouse_pos = if (mx >= 0 and mx < ww and my >= 0 and my < wh)
            vec2u(@intCast(mx), @intCast(my))
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

                if (c.igCheckbox("Wait for VSync", &wait_for_vsync)) {
                    graphics_outdated = true;
                }

                if (c.igButton("Play Sound", .{ .x = 0, .y = 0 })) {
                    ac.playSound(&assets.ball_reflect.hash) catch |err| std.log.err("Failed to play sound: {}", .{err});
                }

                if (c.igButton("Open Demo Window", .{ .x = 0, .y = 0 })) is_demo_open = true;
            }
        }

        ic.render();

        draw_list.clear();
        try game.draw(&draw_list);

        const vertices = try executeDrawList(&draw_list, &game, allocator);
        defer allocator.free(vertices);

        const vertex_buffer_opt = &vertex_buffers[swapchain.image_index];
        if (vertex_buffer_opt.*) |*vb| {
            const size: vk.DeviceSize = @intCast(vertices.len * @sizeOf(Vertex));
            if (vb.info.size < size) {
                vb.deinit(gc);
                vertex_buffer_opt.* = null;
            }
        }
        if (vertex_buffer_opt.* == null) {
            vertex_buffer_opt.* = try Buffer.init(gc, .{ .size = @intCast(vertices.len * @sizeOf(Vertex)) });
        }
        const vb = &vertex_buffer_opt.*.?;

        try uploadVertices(gc, pool, vb.handle, vertices);

        const cmdbuf = cmdbufs[swapchain.image_index];
        const current_image = try swapchain.acquireImage();
        try recordCommandBuffer(
            gc,
            &ic,
            vertices,
            vb.handle,
            swapchain.extent,
            render_pass,
            pipeline,
            cmdbuf,
            framebuffers[swapchain.image_index],
        );

        const state = swapchain.present(cmdbuf, current_image) catch |err| switch (err) {
            error.OutOfDateKHR => Swapchain.PresentState.suboptimal,
            else => |narrow| return narrow,
        };

        if (state == .suboptimal or extent.width != @as(u32, @intCast(fw)) or extent.height != @as(u32, @intCast(fh)) or graphics_outdated) {
            extent.width = @intCast(fw);
            extent.height = @intCast(fh);
            try swapchain.recreate(extent, wait_for_vsync);

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

            graphics_outdated = false;
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

const BufferInfo = struct {
    size: vk.DeviceSize,
    is_host_writable: bool = false,
};

const Buffer = struct {
    handle: vk.Buffer,
    memory: vk.DeviceMemory,
    info: BufferInfo,

    pub fn init(gc: *const GraphicsContext, info: BufferInfo) !Buffer {
        const handle = try gc.vkd.createBuffer(gc.dev, &.{
            .size = info.size,
            .usage = .{ .transfer_dst_bit = true, .vertex_buffer_bit = true },
            .sharing_mode = .exclusive,
        }, null);
        errdefer gc.vkd.destroyBuffer(gc.dev, handle, null);
        const mem_reqs = gc.vkd.getBufferMemoryRequirements(gc.dev, handle);
        const memory = try gc.allocate(mem_reqs, .{
            .device_local_bit = !info.is_host_writable,
            .host_visible_bit = info.is_host_writable,
            .host_coherent_bit = info.is_host_writable,
        });
        errdefer gc.vkd.freeMemory(gc.dev, memory, null);
        try gc.vkd.bindBufferMemory(gc.dev, handle, memory, 0);

        return .{ .handle = handle, .memory = memory, .info = info };
    }

    pub fn deinit(self: *Buffer, gc: *const GraphicsContext) void {
        gc.vkd.freeMemory(gc.dev, self.memory, null);
        gc.vkd.destroyBuffer(gc.dev, self.handle, null);
    }
};

// TODO: Instancing.
fn executeDrawList(draw_list: *const DrawList, game: *const Game, allocator: Allocator) ![]Vertex {
    var vertices = std.ArrayList(Vertex).init(allocator);
    errdefer vertices.deinit();

    const game_size = math.vec2Cast(f32, game.size);
    // Invert y-axis since zlm assumes OpenGL axes, but Vulkan's y-axis is the opposite direction.
    const model = zlm.Mat4.createOrthogonal(0, game_size.x, game_size.y, 0, 0.01, 1);

    // TODO: Use lines topology with separate pipeline.
    for (draw_list.lines.items) |line| {
        for (line.points) |point| {
            const point_size = Vec2.one.scale(2);
            const min = point.pos.sub(point_size.scale(0.5));
            const max = point.pos.add(point_size.scale(0.5));

            var point_verts = [_]Vertex{
                .{ .pos = min, .color = vec3(1, 0, 0) },
                .{ .pos = max, .color = vec3(0, 1, 0) },
                .{ .pos = vec2(min.x, max.y), .color = vec3(0, 0, 1) },
                .{ .pos = min, .color = vec3(1, 0, 0) },
                .{ .pos = vec2(max.x, min.y), .color = vec3(0.25, 0, 1) },
                .{ .pos = max, .color = vec3(0, 1, 0) },
            };
            for (&point_verts) |*v| {
                var pos = zlm.vec4(v.pos.x, v.pos.y, 0, 1);
                pos = pos.transform(model);
                v.pos = vec2(pos.x, pos.y);
            }

            try vertices.appendSlice(&point_verts);
        }
    }

    // TODO: Use points topology with separate pipeline.
    for (draw_list.points.items) |point| {
        const point_size = Vec2.one.scale(2);
        const min = point.pos.sub(point_size.scale(0.5));
        const max = point.pos.add(point_size.scale(0.5));

        var point_verts = [_]Vertex{
            .{ .pos = min, .color = vec3(1, 0, 0) },
            .{ .pos = max, .color = vec3(0, 1, 0) },
            .{ .pos = vec2(min.x, max.y), .color = vec3(0, 0, 1) },
            .{ .pos = min, .color = vec3(1, 0, 0) },
            .{ .pos = vec2(max.x, min.y), .color = vec3(0.25, 0, 1) },
            .{ .pos = max, .color = vec3(0, 1, 0) },
        };
        for (&point_verts) |*v| {
            var pos = zlm.vec4(v.pos.x, v.pos.y, 0, 1);
            pos = pos.transform(model);
            v.pos = vec2(pos.x, pos.y);
        }

        try vertices.appendSlice(&point_verts);
    }

    for (draw_list.rects.items) |rect| {
        var rect_verts = [_]Vertex{
            .{ .pos = rect.min, .color = vec3(1, 0, 0) },
            .{ .pos = rect.max, .color = vec3(0, 1, 0) },
            .{ .pos = vec2(rect.min.x, rect.max.y), .color = vec3(0, 0, 1) },
            .{ .pos = rect.min, .color = vec3(1, 0, 0) },
            .{ .pos = vec2(rect.max.x, rect.min.y), .color = vec3(0.25, 0, 1) },
            .{ .pos = rect.max, .color = vec3(0, 1, 0) },
        };
        for (&rect_verts) |*v| {
            var pos = zlm.vec4(v.pos.x, v.pos.y, 0, 1);
            pos = pos.transform(model);
            v.pos = vec2(pos.x, pos.y);
        }

        try vertices.appendSlice(&rect_verts);
    }

    return try vertices.toOwnedSlice();
}

fn uploadVertices(
    gc: *const GraphicsContext,
    pool: vk.CommandPool,
    buffer: vk.Buffer,
    vertices: []const Vertex,
) !void {
    const vertex_data_size = vertices.len * @sizeOf(Vertex);

    const staging_buffer = try gc.vkd.createBuffer(gc.dev, &.{
        .size = vertex_data_size,
        .usage = .{ .transfer_src_bit = true },
        .sharing_mode = .exclusive,
    }, null);
    defer gc.vkd.destroyBuffer(gc.dev, staging_buffer, null);
    const mem_reqs = gc.vkd.getBufferMemoryRequirements(gc.dev, staging_buffer);
    const staging_memory = try gc.allocate(mem_reqs, .{ .host_visible_bit = true, .host_coherent_bit = true });
    defer gc.vkd.freeMemory(gc.dev, staging_memory, null);
    try gc.vkd.bindBufferMemory(gc.dev, staging_buffer, staging_memory, 0);

    {
        const data = try gc.vkd.mapMemory(gc.dev, staging_memory, 0, vk.WHOLE_SIZE, .{});
        defer gc.vkd.unmapMemory(gc.dev, staging_memory);

        const gpu_vertices: [*]Vertex = @ptrCast(@alignCast(data));
        @memcpy(gpu_vertices, vertices);
    }

    try copyBuffer(gc, pool, buffer, staging_buffer, vertex_data_size);
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
    vertices: []const Vertex,
    buffer: vk.Buffer,
    extent: vk.Extent2D,
    render_pass: vk.RenderPass,
    pipeline: vk.Pipeline,
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

    gc.vkd.cmdBeginRenderPass(cmdbuf, &.{
        .render_pass = render_pass,
        .framebuffer = framebuffer,
        .render_area = render_area,
        .clear_value_count = 1,
        .p_clear_values = @as([*]const vk.ClearValue, @ptrCast(&clear)),
    }, .@"inline");

    gc.vkd.cmdBindPipeline(cmdbuf, .graphics, pipeline);
    const offset = [_]vk.DeviceSize{0};
    gc.vkd.cmdBindVertexBuffers(cmdbuf, 0, 1, @ptrCast(&buffer), &offset);
    gc.vkd.cmdDraw(cmdbuf, @intCast(vertices.len), 1, 0, 0);

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
) !vk.Pipeline {
    const vert = try gc.vkd.createShaderModule(gc.dev, &.{
        .code_size = shaders.triangle_vert.len,
        .p_code = @as([*]const u32, @ptrCast(&shaders.triangle_vert)),
    }, null);
    defer gc.vkd.destroyShaderModule(gc.dev, vert, null);

    const frag = try gc.vkd.createShaderModule(gc.dev, &.{
        .code_size = shaders.triangle_frag.len,
        .p_code = @as([*]const u32, @ptrCast(&shaders.triangle_frag)),
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
        .topology = .triangle_list,
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
        .blend_enable = vk.FALSE,
        .src_color_blend_factor = .one,
        .dst_color_blend_factor = .zero,
        .color_blend_op = .add,
        .src_alpha_blend_factor = .one,
        .dst_alpha_blend_factor = .zero,
        .alpha_blend_op = .add,
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
