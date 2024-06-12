const std = @import("std");
const shaders = @import("shaders");
const vk = @import("vulkan");
const c = @import("../../c.zig");
const math = @import("../../math.zig");
const glfw = @import("mach-glfw");
const zlm = @import("zlm");
const Game = @import("../../game/game.zig").Game;
const Buffer = @import("buffer.zig").Buffer;
const GraphicsContext = @import("graphics_context.zig").GraphicsContext;
const Swapchain = @import("swapchain.zig").Swapchain;
const ImGuiContext = @import("imgui_context.zig").ImGuiContext;
const Vertex = @import("../graphics.zig").Vertex;
const PushConstants = @import("../graphics.zig").PushConstants;
const DrawList = @import("../../game/game.zig").DrawList;
const Instance = DrawList.Instance;
const PointVertex = DrawList.PointVertex;
const Allocator = std.mem.Allocator;
const MemoryPoolExtra = std.heap.MemoryPoolExtra;
const rect_verts = @import("../graphics.zig").rect_verts;
const rect_indices = @import("../graphics.zig").rect_indices;

allocator: Allocator,
window: glfw.Window,
gc: *GraphicsContext,
ic: ImGuiContext,
swapchain: Swapchain,
extent: vk.Extent2D,
pipelines: Pipelines,
pipeline_layout: vk.PipelineLayout,
render_pass: vk.RenderPass,
framebuffers: []vk.Framebuffer,
pool: vk.CommandPool,
cmdbufs: []vk.CommandBuffer,
rect_vertex_buffer: Buffer(Vertex),
rect_index_buffer: Buffer(u16),
rect_instance_buffers: []Buffer(Instance),
point_vertex_buffers: []Buffer(PointVertex),
line_vertex_buffers: []Buffer(PointVertex),
line_index_buffers: []Buffer(u32),
descriptor_set_layout: vk.DescriptorSetLayout,
descriptor_pool: vk.DescriptorPool,
mask_pool: MaskPool,
masks: std.DoublyLinkedList(MaskNode),
wait_for_vsync: bool,
is_graphics_outdated: bool = false,

const Self = @This();

const log = std.log.scoped(.gfx);

const MaskPool = MemoryPoolExtra(std.DoublyLinkedList(MaskNode).Node, .{ .growable = false });

pub fn init(
    allocator: Allocator,
    window: glfw.Window,
    app_name: [*:0]const u8,
    wait_for_vsync: bool,
) !Self {
    if (!glfw.vulkanSupported()) {
        log.err("GLFW could not find libvulkan", .{});
        return error.NoVulkan;
    }

    const frame_size = window.getFramebufferSize();
    const extent = vk.Extent2D{ .width = frame_size.width, .height = frame_size.height };

    const gc = try GraphicsContext.init(allocator, app_name, window);
    errdefer gc.deinit();

    var swapchain = try Swapchain.init(gc, allocator, extent, wait_for_vsync);
    errdefer swapchain.deinit();

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
    errdefer gc.vkd.destroyDescriptorSetLayout(gc.dev, descriptor_set_layout, null);

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
    errdefer gc.vkd.destroyPipelineLayout(gc.dev, pipeline_layout, null);

    const render_pass = try createRenderPass(gc, swapchain);
    errdefer gc.vkd.destroyRenderPass(gc.dev, render_pass, null);

    const pipelines = try createPipelines(gc, pipeline_layout, render_pass);
    errdefer destroyPipelines(pipelines, gc);

    const framebuffers = try createFramebuffers(gc, allocator, render_pass, swapchain);
    errdefer destroyFramebuffers(gc, allocator, framebuffers);

    const pool = try gc.vkd.createCommandPool(gc.dev, &.{
        .queue_family_index = gc.graphics_queue.family,
        .flags = .{ .reset_command_buffer_bit = true },
    }, null);
    errdefer gc.vkd.destroyCommandPool(gc.dev, pool, null);

    var ic = try ImGuiContext.init(gc, &swapchain, allocator, render_pass, window);
    errdefer ic.deinit();

    const cmdbufs = try createCommandBuffers(
        gc,
        pool,
        allocator,
        framebuffers,
    );
    errdefer destroyCommandBuffers(gc, pool, allocator, cmdbufs);

    var rect_vertex_buffer = try Buffer(Vertex).initWithCapacity(gc, rect_verts.len, .{
        .usage = .{
            .transfer_dst_bit = true,
            .vertex_buffer_bit = true,
        },
        .sharing_mode = .exclusive,
        .mem_flags = .{ .device_local_bit = true },
    });
    errdefer rect_vertex_buffer.deinit(gc);
    try rect_vertex_buffer.upload(gc, pool, &rect_verts);

    var rect_index_buffer = try Buffer(u16).initWithCapacity(gc, rect_indices.len, .{
        .usage = .{
            .transfer_dst_bit = true,
            .index_buffer_bit = true,
        },
        .sharing_mode = .exclusive,
        .mem_flags = .{ .device_local_bit = true },
    });
    errdefer rect_index_buffer.deinit(gc);
    try rect_index_buffer.upload(gc, pool, &rect_indices);

    const rect_instance_buffers = try allocator.alloc(Buffer(Instance), swapchain.swap_images.len);
    for (rect_instance_buffers) |*ib| ib.* = Buffer(Instance).init(.{
        .usage = .{ .vertex_buffer_bit = true },
        .sharing_mode = .exclusive,
        .mem_flags = .{ .host_visible_bit = true, .host_coherent_bit = true },
    });
    errdefer {
        for (rect_instance_buffers) |*b| b.deinit(gc);
        allocator.free(rect_instance_buffers);
    }

    const point_vertex_buffers = try allocator.alloc(Buffer(PointVertex), swapchain.swap_images.len);
    for (point_vertex_buffers) |*ib| ib.* = Buffer(PointVertex).init(.{
        .usage = .{ .vertex_buffer_bit = true },
        .sharing_mode = .exclusive,
        .mem_flags = .{ .host_visible_bit = true, .host_coherent_bit = true },
    });
    errdefer {
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
    errdefer {
        for (line_vertex_buffers) |*b| b.deinit(gc);
        allocator.free(line_vertex_buffers);
    }

    const line_index_buffers = try allocator.alloc(Buffer(u32), swapchain.swap_images.len);
    for (line_index_buffers) |*ib| ib.* = Buffer(u32).init(.{
        .usage = .{ .index_buffer_bit = true },
        .sharing_mode = .exclusive,
        .mem_flags = .{ .host_visible_bit = true, .host_coherent_bit = true },
    });
    errdefer {
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
    errdefer gc.vkd.destroyDescriptorPool(gc.dev, descriptor_pool, null);

    var mask_pool = try MaskPool.initPreheated(allocator, swapchain.swap_images.len);
    errdefer mask_pool.deinit();

    var masks = std.DoublyLinkedList(MaskNode){};
    errdefer while (masks.pop()) |node| {
        node.data.buffer.deinit(gc);
        node.data.mask.deinit(gc, descriptor_pool);
    };

    return .{
        .allocator = allocator,
        .window = window,
        .gc = gc,
        .ic = ic,
        .swapchain = swapchain,
        .extent = extent,
        .pipelines = pipelines,
        .pipeline_layout = pipeline_layout,
        .render_pass = render_pass,
        .framebuffers = framebuffers,
        .pool = pool,
        .cmdbufs = cmdbufs,
        .rect_vertex_buffer = rect_vertex_buffer,
        .rect_index_buffer = rect_index_buffer,
        .rect_instance_buffers = rect_instance_buffers,
        .point_vertex_buffers = point_vertex_buffers,
        .line_vertex_buffers = line_vertex_buffers,
        .line_index_buffers = line_index_buffers,
        .descriptor_set_layout = descriptor_set_layout,
        .descriptor_pool = descriptor_pool,
        .mask_pool = mask_pool,
        .masks = masks,
        .wait_for_vsync = wait_for_vsync,
    };
}

pub fn deinit(self: *Self) void {
    self.swapchain.waitForAllFences() catch {};
    self.gc.vkd.deviceWaitIdle(self.gc.dev) catch return;

    while (self.masks.pop()) |node| {
        node.data.buffer.deinit(self.gc);
        node.data.mask.deinit(self.gc, self.descriptor_pool);
    }
    self.mask_pool.deinit();
    self.gc.vkd.destroyDescriptorPool(self.gc.dev, self.descriptor_pool, null);
    self.rect_vertex_buffer.deinit(self.gc);
    self.rect_index_buffer.deinit(self.gc);

    for (self.rect_instance_buffers) |*b| b.deinit(self.gc);
    self.allocator.free(self.rect_instance_buffers);

    for (self.point_vertex_buffers) |*b| b.deinit(self.gc);
    self.allocator.free(self.point_vertex_buffers);

    for (self.line_vertex_buffers) |*b| b.deinit(self.gc);
    self.allocator.free(self.line_vertex_buffers);

    for (self.line_index_buffers) |*b| b.deinit(self.gc);
    self.allocator.free(self.line_index_buffers);

    destroyCommandBuffers(self.gc, self.pool, self.allocator, self.cmdbufs);
    self.ic.deinit();
    self.gc.vkd.destroyCommandPool(self.gc.dev, self.pool, null);
    destroyFramebuffers(self.gc, self.allocator, self.framebuffers);
    destroyPipelines(self.pipelines, self.gc);
    self.gc.vkd.destroyRenderPass(self.gc.dev, self.render_pass, null);
    self.gc.vkd.destroyPipelineLayout(self.gc.dev, self.pipeline_layout, null);
    self.gc.vkd.destroyDescriptorSetLayout(self.gc.dev, self.descriptor_set_layout, null);
    self.swapchain.deinit();
    self.gc.deinit();
}

pub fn renderFrame(self: *Self, game: *const Game, draw_list: *const DrawList) !void {
    const current_image = try self.swapchain.acquireImage();

    const cmdbuf = self.cmdbufs[self.swapchain.image_index];
    const rect_instance_buffer = &self.rect_instance_buffers[self.swapchain.image_index];
    const masked_rects_start = draw_list.rects.items.len;
    const num_rects = masked_rects_start + draw_list.masked_rects.items.len;
    if (draw_list.rects.items.len > 0) {
        try rect_instance_buffer.ensureTotalCapacity(self.gc, num_rects);
        const gpu_instances = try rect_instance_buffer.map(self.gc);
        defer rect_instance_buffer.unmap(self.gc);
        @memcpy(gpu_instances, draw_list.rects.items);
        @memcpy(gpu_instances + masked_rects_start, draw_list.masked_rects.items);
    }
    rect_instance_buffer.len = num_rects;

    const point_vertex_buffer = &self.point_vertex_buffers[self.swapchain.image_index];
    if (draw_list.point_verts.items.len > 0) {
        try point_vertex_buffer.ensureTotalCapacity(self.gc, draw_list.point_verts.items.len);
        const gpu_points = try point_vertex_buffer.map(self.gc);
        defer point_vertex_buffer.unmap(self.gc);
        @memcpy(gpu_points, draw_list.point_verts.items);
    }
    point_vertex_buffer.len = draw_list.point_verts.items.len;

    const line_vertex_buffer = &self.line_vertex_buffers[self.swapchain.image_index];
    if (draw_list.line_verts.items.len > 0) {
        try line_vertex_buffer.ensureTotalCapacity(self.gc, draw_list.line_verts.items.len);
        const gpu_lines = try line_vertex_buffer.map(self.gc);
        defer line_vertex_buffer.unmap(self.gc);
        @memcpy(gpu_lines, draw_list.line_verts.items);
    }
    line_vertex_buffer.len = draw_list.line_verts.items.len;

    const line_index_buffer = &self.line_index_buffers[self.swapchain.image_index];
    if (draw_list.line_indices.items.len > 0) {
        try line_index_buffer.ensureTotalCapacity(self.gc, draw_list.line_indices.items.len);
        const gpu_indices = try line_index_buffer.map(self.gc);
        defer line_index_buffer.unmap(self.gc);
        @memcpy(gpu_indices, draw_list.line_indices.items);
    }
    line_index_buffer.len = draw_list.line_indices.items.len;

    {
        var node = self.masks.first;
        while (node) |n| {
            const next = n.next;
            defer node = next;

            n.data.frames_lived += 1;
            if (n.data.frames_lived >= self.swapchain.swap_images.len) {
                self.masks.remove(n);
                n.data.buffer.deinit(self.gc);
                n.data.mask.deinit(self.gc, self.descriptor_pool);
                self.mask_pool.destroy(n);
            }
        }
    }

    // TODO: Put in arena?
    var rect_masks = std.ArrayList(*const MaskNode).init(self.allocator);
    defer rect_masks.deinit();

    for (draw_list.rect_masks.items) |rect_mask| {
        var mask = Mask.init(self.gc, self.descriptor_set_layout, self.descriptor_pool, .{
            .width = rect_mask.width,
            .height = rect_mask.height,
        }) catch |err| {
            std.log.err("Failed to create mask: {}", .{err});
            return err;
        };
        errdefer mask.deinit(self.gc, self.descriptor_pool);

        var buffer = try Buffer(u8).initWithCapacity(self.gc, rect_mask.pixels.len, .{
            .usage = .{ .transfer_src_bit = true },
            .sharing_mode = .exclusive,
            .mem_flags = .{ .host_visible_bit = true, .host_coherent_bit = true },
        });
        errdefer buffer.deinit(self.gc);

        {
            const gpu_pixels = try buffer.map(self.gc);
            defer buffer.unmap(self.gc);
            @memcpy(gpu_pixels, rect_mask.pixels);
        }

        const node = try self.mask_pool.create();
        errdefer self.mask_pool.destroy(node);
        node.data = .{ .mask = mask, .buffer = buffer };

        self.masks.append(node);
        errdefer self.masks.remove(node);

        try rect_masks.append(&node.data);
    }

    try recordCommandBuffer(
        self.gc,
        &self.ic,
        game,
        &self.rect_vertex_buffer,
        &self.rect_index_buffer,
        rect_instance_buffer,
        masked_rects_start,
        rect_masks.items,
        point_vertex_buffer,
        line_vertex_buffer,
        line_index_buffer,
        self.swapchain.extent,
        self.render_pass,
        self.pipelines,
        self.pipeline_layout,
        cmdbuf,
        self.framebuffers[self.swapchain.image_index],
    );

    const state = self.swapchain.present(cmdbuf, current_image) catch |err| switch (err) {
        error.OutOfDateKHR => Swapchain.PresentState.suboptimal,
        else => |narrow| return narrow,
    };

    const frame_size = self.window.getFramebufferSize();

    if (state == .suboptimal or self.extent.width != frame_size.width or self.extent.height != frame_size.height or self.is_graphics_outdated) {
        self.extent.width = frame_size.width;
        self.extent.height = frame_size.height;
        try self.swapchain.recreate(self.extent, self.wait_for_vsync);

        destroyFramebuffers(self.gc, self.allocator, self.framebuffers);
        self.framebuffers = try createFramebuffers(self.gc, self.allocator, self.render_pass, self.swapchain);

        destroyCommandBuffers(self.gc, self.pool, self.allocator, self.cmdbufs);
        self.cmdbufs = try createCommandBuffers(
            self.gc,
            self.pool,
            self.allocator,
            self.framebuffers,
        );

        try self.ic.resize(&self.swapchain);

        self.is_graphics_outdated = false;
    }

    self.ic.postPresent();
}

pub fn igImplNewFrame() void {
    c.ImGui_ImplVulkan_NewFrame();
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
        zlm.vec2(1.0 / aspect_ratio, 1)
    else
        zlm.vec2(1, aspect_ratio);

    const push_constants: PushConstants = .{
        .view = view.mul(zlm.Mat4.createScale(aspect.x, aspect.y, 1)),
        .aspect = aspect,
        .viewport_size = zlm.vec2(@floatFromInt(extent.width), @floatFromInt(extent.height)),
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

    if (line_index_buffer.handle != .null_handle) {
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
