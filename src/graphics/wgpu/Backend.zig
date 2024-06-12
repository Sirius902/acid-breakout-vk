const std = @import("std");
const glfw = @import("mach-glfw");
const zlm = @import("zlm");
const c = @import("../../c.zig");
const math = @import("../../math.zig");
const Game = @import("../../game/game.zig").Game;
const DrawList = @import("../../game/game.zig").DrawList;
const Vertex = @import("../graphics.zig").Vertex;
const Instance = DrawList.Instance;
const PointVertex = DrawList.PointVertex;
const Allocator = std.mem.Allocator;

allocator: Allocator,
instance: c.WGPUInstance,
adapter: c.WGPUAdapter,
surface: c.WGPUSurface,
device: c.WGPUDevice,
error_logger: *ErrorLogger,
queue: c.WGPUQueue,
surface_format: c.WGPUTextureFormat,
surface_extent: Extent2D,
pipelines: Pipelines,
buffers: Buffers,
uniform_bind_group: c.WGPUBindGroup,
srgb_to_lrgb_pass: ?SrgbToLrgbPass,
window: glfw.Window,
wait_for_vsync: bool,
is_graphics_outdated: bool = false,

const Self = @This();

const log = std.log.scoped(.gfx);
const shader_source = @embedFile("shaders/shader.wgsl");
const srgb_to_lrgb_shader_source = @embedFile("shaders/srgb_to_lrgb.wgsl");
const rect_verts = @import("../graphics.zig").rect_verts;
const rect_indices = @import("../graphics.zig").rect_indices;

const Extent2D = struct {
    width: u32,
    height: u32,

    pub fn eql(self: @This(), other: @This()) bool {
        return self.width == other.width and self.height == other.height;
    }
};

// WGSL alignment differs from zlm's alignment.
const UniformBufferObject = extern struct {
    view: zlm.Mat4 align(16),
    aspect: zlm.Vec2 align(8),
    viewport_size: zlm.Vec2 align(8),
    time: f32,
    color_correction: u32,
};

pub fn init(
    allocator: Allocator,
    window: glfw.Window,
    app_name: [*:0]const u8,
    wait_for_vsync: bool,
) !Self {
    var desc: c.WGPUInstanceDescriptor = .{};
    desc.nextInChain = null;

    const instance = c.wgpuCreateInstance(&desc);
    errdefer c.wgpuInstanceRelease(instance);

    const options: c.WGPURequestAdapterOptions = .{};
    const adapter = requestAdapter(instance, &options);
    errdefer c.wgpuAdapterRelease(adapter);

    const surface = c.glfwGetWGPUSurface(instance, @ptrCast(window.handle));
    errdefer c.wgpuSurfaceRelease(surface);

    const device_desc: c.WGPUDeviceDescriptor = .{
        .label = app_name,
        .defaultQueue = .{ .label = "Default Queue" },
    };
    const device = requestDevice(adapter, &device_desc);
    errdefer c.wgpuDeviceRelease(device);

    const error_logger = try ErrorLogger.init(allocator);
    errdefer error_logger.deinit();

    error_logger.logUncapturedDeviceError(device);

    const queue = c.wgpuDeviceGetQueue(device);
    errdefer c.wgpuQueueRelease(queue);

    const surface_format = c.wgpuSurfaceGetPreferredFormat(surface, adapter);
    const surface_extent = getSurfaceExtent(window);

    configureSurface(device, surface, surface_extent, surface_format, wait_for_vsync);

    const pipelines = try Pipelines.init(device, surface_format);
    errdefer pipelines.deinit();

    const buffers = Buffers.init(device, queue);
    errdefer buffers.deinit();

    const uniform_binding: c.WGPUBindGroupEntry = .{
        .binding = 0,
        .size = @sizeOf(UniformBufferObject),
        .offset = 0,
        .buffer = buffers.uniform_buffer,
    };
    const uniform_bind_group = c.wgpuDeviceCreateBindGroup(device, &.{
        .label = "Uniform Bind Group",
        .layout = pipelines.bind_group_layout,
        .entryCount = 1,
        .entries = &uniform_binding,
    });
    errdefer c.wgpuBindGroupRelease(uniform_bind_group);

    // TODO: Fix pipeline alpha blending to be the same on lRGB and sRGB in both WebGPU and Vulkan backends.
    const srgb_to_lrgb_pass = if (isSrgb(surface_format)) SrgbToLrgbPass.init(device, surface_extent, surface_format) else null;
    errdefer if (srgb_to_lrgb_pass) |*p| p.deinit();

    const imgui_rt_format: c.WGPUTextureFormat = if (isSrgb(surface_format))
        c.WGPUTextureFormat_BGRA8Unorm
    else
        surface_format;

    if (!c.ImGui_ImplGlfw_InitForOther(@ptrCast(window.handle), true)) return error.ImGuiGlfwInit;
    if (!c.ImGui_ImplWGPU_Init(device, 1, imgui_rt_format, c.WGPUTextureFormat_Undefined)) return error.ImGuiWGPUInit;
    errdefer c.ImGui_ImplWGPU_Shutdown();

    return .{
        .allocator = allocator,
        .instance = instance,
        .adapter = adapter,
        .surface = surface,
        .device = device,
        .error_logger = error_logger,
        .queue = queue,
        .surface_format = surface_format,
        .surface_extent = surface_extent,
        .pipelines = pipelines,
        .buffers = buffers,
        .uniform_bind_group = uniform_bind_group,
        .srgb_to_lrgb_pass = srgb_to_lrgb_pass,
        .window = window,
        .wait_for_vsync = wait_for_vsync,
    };
}

pub fn deinit(self: *Self) void {
    c.ImGui_ImplWGPU_Shutdown();
    if (self.srgb_to_lrgb_pass) |*p| p.deinit();
    c.wgpuBindGroupRelease(self.uniform_bind_group);
    self.buffers.deinit();
    self.pipelines.deinit();
    self.error_logger.deinit();
    c.wgpuQueueRelease(self.queue);
    c.wgpuDeviceRelease(self.device);
    c.wgpuSurfaceRelease(self.surface);
    c.wgpuAdapterRelease(self.adapter);
    c.wgpuInstanceRelease(self.instance);
}

pub fn renderFrame(self: *Self, game: *const Game, draw_list: *const DrawList) !void {
    const current_surface_extent = getSurfaceExtent(self.window);
    if (self.is_graphics_outdated or !self.surface_extent.eql(current_surface_extent)) {
        self.surface_extent = current_surface_extent;
        configureSurface(self.device, self.surface, self.surface_extent, self.surface_format, self.wait_for_vsync);

        if (self.srgb_to_lrgb_pass) |*cc_pass| {
            cc_pass.resize(self.device, self.surface_extent);
        }

        self.is_graphics_outdated = false;
    }

    var encoder_desc: c.WGPUCommandEncoderDescriptor = .{ .label = "Render Command Encoder" };
    const encoder = c.wgpuDeviceCreateCommandEncoder(self.device, &encoder_desc);
    defer c.wgpuCommandEncoderRelease(encoder);

    var surface_texture: c.WGPUSurfaceTexture = undefined;
    c.wgpuSurfaceGetCurrentTexture(self.surface, &surface_texture);

    const next_texture_desc: c.WGPUTextureViewDescriptor = .{
        .label = "Surface Texture View",
        .format = self.surface_format,
        .dimension = c.WGPUTextureViewDimension_2D,
        .mipLevelCount = 1,
        .baseMipLevel = 0,
        .arrayLayerCount = 1,
        .baseArrayLayer = 0,
        .aspect = c.WGPUTextureAspect_All,
    };
    const next_texture = c.wgpuTextureCreateView(surface_texture.texture, &next_texture_desc);
    defer c.wgpuTextureViewRelease(next_texture);

    if (self.srgb_to_lrgb_pass) |*cc_pass| {
        const render_pass_color_attachment: c.WGPURenderPassColorAttachment = .{
            .view = cc_pass.texture_view,
            .loadOp = c.WGPULoadOp_Clear,
            .storeOp = c.WGPUStoreOp_Store,
            .clearValue = c.WGPUColor{ .r = 0.0, .g = 0.0, .b = 0.0, .a = 0.0 },
        };

        const render_pass_desc: c.WGPURenderPassDescriptor = .{
            .label = "sRGB to lRGB Render Pass",
            .colorAttachmentCount = 1,
            .colorAttachments = &render_pass_color_attachment,
        };
        const render_pass = c.wgpuCommandEncoderBeginRenderPass(encoder, &render_pass_desc);

        if (c.igGetDrawData()) |ig_draw_data| {
            c.ImGui_ImplWGPU_RenderDrawData(ig_draw_data, render_pass);
        }

        c.wgpuRenderPassEncoderEnd(render_pass);
        c.wgpuRenderPassEncoderRelease(render_pass);
    }

    const render_pass_color_attachment: c.WGPURenderPassColorAttachment = .{
        .view = next_texture,
        .loadOp = c.WGPULoadOp_Clear,
        .storeOp = c.WGPUStoreOp_Store,
        .clearValue = c.WGPUColor{ .r = 0.0, .g = 0.0, .b = 0.0, .a = 1.0 },
    };

    const render_pass_desc: c.WGPURenderPassDescriptor = .{
        .label = "Main Render Pass",
        .colorAttachmentCount = 1,
        .colorAttachments = &render_pass_color_attachment,
    };
    const render_pass = c.wgpuCommandEncoderBeginRenderPass(encoder, &render_pass_desc);

    const game_size = math.vec2Cast(f32, game.size);
    const view = zlm.Mat4.createOrthogonal(0, game_size.x, 0, game_size.y, 0, 1);

    const viewport = zlm.vec2(@floatFromInt(self.surface_extent.width), @floatFromInt(self.surface_extent.height));
    const aspect_ratio = (viewport.x / game_size.x) / (viewport.y / game_size.y);
    const aspect = if (viewport.x >= viewport.y)
        zlm.vec2(1.0 / aspect_ratio, 1)
    else
        zlm.vec2(1, aspect_ratio);

    const ubo: UniformBufferObject = .{
        .view = view.mul(zlm.Mat4.createScale(aspect.x, aspect.y, 1)),
        .aspect = aspect,
        .viewport_size = viewport,
        .time = game.time,
        .color_correction = if (isSrgb(self.surface_format)) 0 else 1,
    };

    self.buffers.update(self.device, self.queue, &ubo, draw_list);

    c.wgpuRenderPassEncoderSetBindGroup(render_pass, 0, self.uniform_bind_group, 0, null);

    if (self.buffers.line_index.len > 0) {
        c.wgpuRenderPassEncoderSetPipeline(render_pass, self.pipelines.line);
        c.wgpuRenderPassEncoderSetVertexBuffer(render_pass, 0, self.buffers.line_vertex.handle, 0, @sizeOf(PointVertex) * @as(u64, self.buffers.line_vertex.len));
        c.wgpuRenderPassEncoderSetIndexBuffer(render_pass, self.buffers.line_index.handle, c.WGPUIndexFormat_Uint32, 0, @sizeOf(u32) * @as(u64, self.buffers.line_index.len));
        c.wgpuRenderPassEncoderDrawIndexed(render_pass, self.buffers.line_index.len, 1, 0, 0, 0);
    }

    if (self.buffers.point_vertex.len > 0) {
        c.wgpuRenderPassEncoderSetPipeline(render_pass, self.pipelines.point);
        c.wgpuRenderPassEncoderSetVertexBuffer(render_pass, 0, self.buffers.point_vertex.handle, 0, @sizeOf(PointVertex) * @as(u64, self.buffers.point_vertex.len));
        c.wgpuRenderPassEncoderDraw(render_pass, self.buffers.point_vertex.len, 1, 0, 0);
    }

    c.wgpuRenderPassEncoderSetVertexBuffer(render_pass, 0, self.buffers.rect_vertex.handle, 0, @sizeOf(Vertex) * @as(u64, self.buffers.rect_vertex.len));
    c.wgpuRenderPassEncoderSetIndexBuffer(render_pass, self.buffers.rect_index.handle, c.WGPUIndexFormat_Uint16, 0, @sizeOf(u16) * @as(u64, self.buffers.rect_index.len));

    if (self.buffers.rect_instance.len > 0) {
        c.wgpuRenderPassEncoderSetPipeline(render_pass, self.pipelines.rect);
        c.wgpuRenderPassEncoderSetVertexBuffer(render_pass, 1, self.buffers.rect_instance.handle, 0, @sizeOf(Instance) * @as(u64, self.buffers.rect_instance.len));
        c.wgpuRenderPassEncoderDrawIndexed(render_pass, self.buffers.rect_index.len, self.buffers.rect_instance.len, 0, 0, 0);
    }

    const masks = try self.allocator.alloc(Mask, draw_list.rect_masks.items.len);
    defer self.allocator.free(masks);

    for (masks, draw_list.rect_masks.items) |*m, rm| {
        m.* = Mask.init(self.device, self.pipelines.mask_bind_group_layout, .{
            .width = rm.width,
            .height = rm.height,
        });

        m.write(self.queue, rm.pixels);
    }
    defer for (masks) |*m| m.deinit();

    if (self.buffers.masked_rect_instance.len > 0) {
        c.wgpuRenderPassEncoderSetPipeline(render_pass, self.pipelines.masked_rect);
        c.wgpuRenderPassEncoderSetVertexBuffer(render_pass, 1, self.buffers.masked_rect_instance.handle, 0, @sizeOf(Instance) * @as(u64, self.buffers.masked_rect_instance.len));

        for (masks, 0..) |mask, i| {
            c.wgpuRenderPassEncoderSetBindGroup(render_pass, 1, mask.bind_group, 0, null);
            c.wgpuRenderPassEncoderDrawIndexed(render_pass, self.buffers.rect_index.len, 1, 0, 0, @intCast(i));
        }
    }

    if (self.srgb_to_lrgb_pass) |*cc_pass| {
        c.wgpuRenderPassEncoderSetBindGroup(render_pass, 0, cc_pass.bind_group, 0, null);
        c.wgpuRenderPassEncoderSetPipeline(render_pass, cc_pass.pipeline);
        c.wgpuRenderPassEncoderDraw(render_pass, 6, 1, 0, 0);
    } else if (c.igGetDrawData()) |ig_draw_data| {
        c.ImGui_ImplWGPU_RenderDrawData(ig_draw_data, render_pass);
    }

    c.wgpuRenderPassEncoderEnd(render_pass);
    c.wgpuRenderPassEncoderRelease(render_pass);

    const cmdbuf_desc: c.WGPUCommandBufferDescriptor = .{ .label = "Render Command Buffer" };
    const cmdbuf = c.wgpuCommandEncoderFinish(encoder, &cmdbuf_desc);
    defer c.wgpuCommandBufferRelease(cmdbuf);

    c.wgpuQueueSubmit(self.queue, 1, &cmdbuf);

    c.wgpuSurfacePresent(self.surface);
}

pub fn igImplNewFrame() void {
    c.ImGui_ImplWGPU_NewFrame();
}

fn requestAdapter(instance: c.WGPUInstance, options: *const c.WGPURequestAdapterOptions) c.WGPUAdapter {
    const AdapterData = struct {
        adapter: c.WGPUAdapter = null,
        request_ended: bool = false,

        pub fn onAdapterRequestEnded(status: c.WGPURequestAdapterStatus, adapter: c.WGPUAdapter, message: [*c]const u8, user_data: ?*anyopaque) callconv(.C) void {
            const self: *@This() = @ptrCast(@alignCast(user_data.?));
            if (status == c.WGPURequestAdapterStatus_Success) {
                self.adapter = adapter;
            } else {
                log.err("WebGPU adapter request failed: {s}", .{message});
            }
            self.request_ended = true;
        }
    };

    var adapter_data: AdapterData = .{};
    c.wgpuInstanceRequestAdapter(instance, options, AdapterData.onAdapterRequestEnded, &adapter_data);

    std.debug.assert(adapter_data.request_ended);

    return adapter_data.adapter;
}

fn requestDevice(adapter: c.WGPUAdapter, descriptor: *const c.WGPUDeviceDescriptor) c.WGPUDevice {
    const DeviceData = struct {
        device: c.WGPUDevice = null,
        request_ended: bool = false,

        pub fn onDeviceRequestEnded(status: c.WGPURequestDeviceStatus, device: c.WGPUDevice, message: [*c]const u8, user_data: ?*anyopaque) callconv(.C) void {
            const self: *@This() = @ptrCast(@alignCast(user_data.?));
            if (status == c.WGPURequestDeviceStatus_Success) {
                self.device = device;
            } else {
                log.err("WebGPU device request failed: {s}", .{message});
            }
            self.request_ended = true;
        }
    };

    var device_data: DeviceData = .{};
    c.wgpuAdapterRequestDevice(adapter, descriptor, DeviceData.onDeviceRequestEnded, &device_data);

    std.debug.assert(device_data.request_ended);

    return device_data.device;
}

fn getSurfaceExtent(window: glfw.Window) Extent2D {
    const frame_size = window.getFramebufferSize();
    return .{ .width = frame_size.width, .height = frame_size.height };
}

fn configureSurface(
    device: c.WGPUDevice,
    surface: c.WGPUSurface,
    surface_extent: Extent2D,
    surface_format: c.WGPUTextureFormat,
    wait_for_vsync: bool,
) void {
    const surface_config: c.WGPUSurfaceConfiguration = .{
        .device = device,
        .width = surface_extent.width,
        .height = surface_extent.height,
        .format = surface_format,
        .usage = c.WGPUTextureUsage_RenderAttachment,
        .presentMode = if (wait_for_vsync) c.WGPUPresentMode_Fifo else c.WGPUPresentMode_Mailbox,
    };
    return c.wgpuSurfaceConfigure(surface, &surface_config);
}

const Mask = struct {
    texture: c.WGPUTexture,
    extent: Extent2D,
    texture_view: c.WGPUTextureView,
    sampler: c.WGPUSampler,
    bind_group: c.WGPUBindGroup,

    const format = c.WGPUTextureFormat_R8Unorm;

    pub fn init(device: c.WGPUDevice, bind_group_layout: c.WGPUBindGroupLayout, extent: Extent2D) Mask {
        const texture = c.wgpuDeviceCreateTexture(device, &.{
            .label = "Mask Texture",
            .size = .{
                .width = extent.width,
                .height = extent.height,
                .depthOrArrayLayers = 1,
            },
            .format = format,
            .dimension = c.WGPUTextureDimension_2D,
            .mipLevelCount = 1,
            .sampleCount = 1,
            .usage = c.WGPUTextureUsage_TextureBinding | c.WGPUTextureUsage_CopyDst,
        });
        errdefer c.wgpuTextureRelease(texture);

        const texture_view = c.wgpuTextureCreateView(texture, &.{
            .label = "Mask Texture View",
            .format = format,
            .dimension = c.WGPUTextureViewDimension_2D,
            .mipLevelCount = 1,
            .baseMipLevel = 0,
            .arrayLayerCount = 1,
            .baseArrayLayer = 0,
            .aspect = c.WGPUTextureAspect_All,
        });
        errdefer c.wgpuTextureViewRelease(texture_view);

        const sampler = c.wgpuDeviceCreateSampler(device, &.{
            .label = "Mask Sampler",
            .addressModeU = c.WGPUAddressMode_ClampToEdge,
            .addressModeV = c.WGPUAddressMode_ClampToEdge,
            .addressModeW = c.WGPUAddressMode_ClampToEdge,
            .magFilter = c.WGPUFilterMode_Nearest,
            .minFilter = c.WGPUFilterMode_Nearest,
            .mipmapFilter = c.WGPUFilterMode_Nearest,
            .lodMinClamp = 0.0,
            .lodMaxClamp = 32.0,
            .compare = c.WGPUCompareFunction_Undefined,
            .maxAnisotropy = 1.0,
        });
        errdefer c.wgpuSamplerRelease(sampler);

        const bind_group_entries = [_]c.WGPUBindGroupEntry{
            .{
                .binding = 0,
                .textureView = texture_view,
            },
            .{
                .binding = 1,
                .sampler = sampler,
            },
        };
        const bind_group = c.wgpuDeviceCreateBindGroup(device, &.{
            .label = "sRGB to lRGB Bind Group",
            .layout = bind_group_layout,
            .entryCount = bind_group_entries.len,
            .entries = &bind_group_entries,
        });
        errdefer c.wgpuBindGroupRelease(bind_group);

        return .{
            .texture = texture,
            .extent = extent,
            .texture_view = texture_view,
            .sampler = sampler,
            .bind_group = bind_group,
        };
    }

    pub fn deinit(self: *const Mask) void {
        c.wgpuBindGroupRelease(self.bind_group);
        c.wgpuSamplerRelease(self.sampler);
        c.wgpuTextureViewRelease(self.texture_view);
        c.wgpuTextureRelease(self.texture);
    }

    pub fn write(self: *const Mask, queue: c.WGPUQueue, pixels: []const u8) void {
        const mask_size = self.extent.width * self.extent.height;
        std.debug.assert(pixels.len >= mask_size);

        c.wgpuQueueWriteTexture(queue, &.{
            .texture = self.texture,
            .mipLevel = 0,
            .origin = .{ .x = 0, .y = 0, .z = 0 },
            .aspect = c.WGPUTextureAspect_All,
        }, pixels.ptr, pixels.len, &.{
            .offset = 0,
            .bytesPerRow = self.extent.width,
            .rowsPerImage = self.extent.height,
        }, &.{
            .width = self.extent.width,
            .height = self.extent.height,
            .depthOrArrayLayers = 1,
        });
    }
};

const SrgbToLrgbPass = struct {
    texture: c.WGPUTexture,
    texture_view: c.WGPUTextureView,
    sampler: c.WGPUSampler,
    bind_group_layout: c.WGPUBindGroupLayout,
    bind_group: c.WGPUBindGroup,
    pipeline: c.WGPURenderPipeline,

    pub fn init(device: c.WGPUDevice, surface_extent: Extent2D, surface_format: c.WGPUTextureFormat) SrgbToLrgbPass {
        const texture = createTexture(device, surface_extent);
        errdefer c.wgpuTextureRelease(texture);

        const texture_view = c.wgpuTextureCreateView(texture, &.{
            .label = "sRGB to lRGB View",
            .format = c.WGPUTextureFormat_BGRA8Unorm,
            .dimension = c.WGPUTextureViewDimension_2D,
            .mipLevelCount = 1,
            .baseMipLevel = 0,
            .arrayLayerCount = 1,
            .baseArrayLayer = 0,
            .aspect = c.WGPUTextureAspect_All,
        });
        errdefer c.wgpuTextureViewRelease(texture_view);

        const sampler = c.wgpuDeviceCreateSampler(device, &.{
            .label = "sRGB to lRGB Sampler",
            .addressModeU = c.WGPUAddressMode_ClampToEdge,
            .addressModeV = c.WGPUAddressMode_ClampToEdge,
            .addressModeW = c.WGPUAddressMode_ClampToEdge,
            .magFilter = c.WGPUFilterMode_Linear,
            .minFilter = c.WGPUFilterMode_Nearest,
            .mipmapFilter = c.WGPUFilterMode_Nearest,
            .lodMinClamp = 0.0,
            .lodMaxClamp = 32.0,
            .compare = c.WGPUCompareFunction_Undefined,
            .maxAnisotropy = 1.0,
        });
        errdefer c.wgpuSamplerRelease(sampler);

        const bind_group_layout_entries = [_]c.WGPUBindGroupLayoutEntry{
            .{
                .binding = 0,
                .visibility = c.WGPUShaderStage_Fragment,
                .texture = .{
                    .sampleType = c.WGPUTextureSampleType_Float,
                    .viewDimension = c.WGPUTextureViewDimension_2D,
                },
            },
            .{
                .binding = 1,
                .visibility = c.WGPUShaderStage_Fragment,
                .sampler = .{ .type = c.WGPUSamplerBindingType_Filtering },
            },
        };
        const bind_group_layout = c.wgpuDeviceCreateBindGroupLayout(device, &.{
            .label = "sRGB to lRGB Bind Group Layout",
            .entryCount = bind_group_layout_entries.len,
            .entries = &bind_group_layout_entries,
        });
        errdefer c.wgpuBindGroupLayoutRelease(bind_group_layout);

        const bind_group_entries = [_]c.WGPUBindGroupEntry{
            .{
                .binding = 0,
                .textureView = texture_view,
            },
            .{
                .binding = 1,
                .sampler = sampler,
            },
        };
        const bind_group = c.wgpuDeviceCreateBindGroup(device, &.{
            .label = "sRGB to lRGB Bind Group",
            .layout = bind_group_layout,
            .entryCount = bind_group_entries.len,
            .entries = &bind_group_entries,
        });
        errdefer c.wgpuBindGroupRelease(bind_group);

        const pipeline = createPipeline(device, surface_format, bind_group_layout);
        errdefer c.wgpuRenderPipelineRelease(pipeline);

        return .{
            .texture = texture,
            .texture_view = texture_view,
            .sampler = sampler,
            .bind_group_layout = bind_group_layout,
            .bind_group = bind_group,
            .pipeline = pipeline,
        };
    }

    pub fn deinit(self: *const SrgbToLrgbPass) void {
        c.wgpuRenderPipelineRelease(self.pipeline);
        c.wgpuBindGroupRelease(self.bind_group);
        c.wgpuBindGroupLayoutRelease(self.bind_group_layout);
        c.wgpuSamplerRelease(self.sampler);
        c.wgpuTextureViewRelease(self.texture_view);
        c.wgpuTextureRelease(self.texture);
    }

    pub fn resize(self: *SrgbToLrgbPass, device: c.WGPUDevice, surface_extent: Extent2D) void {
        const old_texture = self.texture;
        const old_view = self.texture_view;
        self.texture = createTexture(device, surface_extent);
        self.texture_view = c.wgpuTextureCreateView(self.texture, &.{
            .label = "sRGB to lRGB View",
            .format = c.WGPUTextureFormat_BGRA8Unorm,
            .dimension = c.WGPUTextureViewDimension_2D,
            .mipLevelCount = 1,
            .baseMipLevel = 0,
            .arrayLayerCount = 1,
            .baseArrayLayer = 0,
            .aspect = c.WGPUTextureAspect_All,
        });
        c.wgpuTextureViewRelease(old_view);
        c.wgpuTextureRelease(old_texture);

        const bind_group_entries = [_]c.WGPUBindGroupEntry{
            .{
                .binding = 0,
                .textureView = self.texture_view,
            },
            .{
                .binding = 1,
                .sampler = self.sampler,
            },
        };
        const old_bind_group = self.bind_group;
        self.bind_group = c.wgpuDeviceCreateBindGroup(device, &.{
            .label = "sRGB to lRGB Bind Group",
            .layout = self.bind_group_layout,
            .entryCount = bind_group_entries.len,
            .entries = &bind_group_entries,
        });
        c.wgpuBindGroupRelease(old_bind_group);
    }

    fn createTexture(device: c.WGPUDevice, surface_extent: Extent2D) c.WGPUTexture {
        return c.wgpuDeviceCreateTexture(device, &.{
            .label = "sRGB to lRGB Texture",
            .size = .{
                .width = surface_extent.width,
                .height = surface_extent.height,
                .depthOrArrayLayers = 1,
            },
            .format = c.WGPUTextureFormat_BGRA8Unorm,
            .dimension = c.WGPUTextureDimension_2D,
            .mipLevelCount = 1,
            .sampleCount = 1,
            .usage = c.WGPUTextureUsage_TextureBinding | c.WGPUTextureUsage_RenderAttachment,
        });
    }

    fn createPipeline(device: c.WGPUDevice, surface_format: c.WGPUTextureFormat, bind_group_layout: c.WGPUBindGroupLayout) c.WGPURenderPipeline {
        const shader_code_desc: c.WGPUShaderModuleWGSLDescriptor = .{
            .code = srgb_to_lrgb_shader_source,
            .chain = .{ .sType = c.WGPUSType_ShaderModuleWGSLDescriptor },
        };

        const shader_desc: c.WGPUShaderModuleDescriptor = .{
            .label = "sRGB to lRGB Shader",
            .nextInChain = &shader_code_desc.chain,
        };
        const shader_module = c.wgpuDeviceCreateShaderModule(device, &shader_desc);
        defer c.wgpuShaderModuleRelease(shader_module);

        const blend_state: c.WGPUBlendState = .{
            .color = .{
                .srcFactor = c.WGPUBlendFactor_SrcAlpha,
                .dstFactor = c.WGPUBlendFactor_OneMinusSrcAlpha,
                .operation = c.WGPUBlendOperation_Add,
            },
            .alpha = .{
                .srcFactor = c.WGPUBlendFactor_SrcAlpha,
                .dstFactor = c.WGPUBlendFactor_OneMinusSrcAlpha,
                .operation = c.WGPUBlendOperation_Subtract,
            },
        };

        const color_target: c.WGPUColorTargetState = .{
            .format = surface_format,
            .blend = &blend_state,
            .writeMask = c.WGPUColorWriteMask_All,
        };

        const fragment_state: c.WGPUFragmentState = .{
            .module = shader_module,
            .entryPoint = "fs_main",
            .constantCount = 0,
            .constants = null,
            .targetCount = 1,
            .targets = &color_target,
        };

        const layout = c.wgpuDeviceCreatePipelineLayout(device, &.{
            .label = "sRGB to lRGB Pipeline Layout",
            .bindGroupLayoutCount = 1,
            .bindGroupLayouts = &bind_group_layout,
        });
        defer c.wgpuPipelineLayoutRelease(layout);

        const desc: c.WGPURenderPipelineDescriptor = .{
            .label = "sRGB to lRGB Pipeline",
            .vertex = .{
                .bufferCount = 0,
                .buffers = null,
                .module = shader_module,
                .entryPoint = "vs_main",
                .constantCount = 0,
                .constants = null,
            },
            .fragment = &fragment_state,
            .primitive = .{
                .topology = c.WGPUPrimitiveTopology_TriangleList,
                .stripIndexFormat = c.WGPUIndexFormat_Undefined,
                .frontFace = c.WGPUFrontFace_CCW,
                .cullMode = c.WGPUCullMode_None,
            },
            .depthStencil = null,
            .multisample = .{
                .count = 1,
                .mask = ~@as(u32, 0),
            },
            .layout = layout,
        };

        return c.wgpuDeviceCreateRenderPipeline(device, &desc);
    }
};

fn isSrgb(format: c.WGPUTextureFormat) bool {
    return switch (format) {
        c.WGPUTextureFormat_RGBA8UnormSrgb,
        c.WGPUTextureFormat_BGRA8UnormSrgb,
        c.WGPUTextureFormat_BC1RGBAUnormSrgb,
        c.WGPUTextureFormat_BC2RGBAUnormSrgb,
        c.WGPUTextureFormat_BC3RGBAUnormSrgb,
        c.WGPUTextureFormat_BC7RGBAUnormSrgb,
        c.WGPUTextureFormat_ETC2RGB8UnormSrgb,
        c.WGPUTextureFormat_ETC2RGB8A1UnormSrgb,
        c.WGPUTextureFormat_ETC2RGBA8UnormSrgb,
        c.WGPUTextureFormat_ASTC4x4UnormSrgb,
        c.WGPUTextureFormat_ASTC5x4UnormSrgb,
        c.WGPUTextureFormat_ASTC5x5UnormSrgb,
        c.WGPUTextureFormat_ASTC6x5UnormSrgb,
        c.WGPUTextureFormat_ASTC6x6UnormSrgb,
        c.WGPUTextureFormat_ASTC8x5UnormSrgb,
        c.WGPUTextureFormat_ASTC8x6UnormSrgb,
        c.WGPUTextureFormat_ASTC8x8UnormSrgb,
        c.WGPUTextureFormat_ASTC10x5UnormSrgb,
        c.WGPUTextureFormat_ASTC10x6UnormSrgb,
        c.WGPUTextureFormat_ASTC10x8UnormSrgb,
        c.WGPUTextureFormat_ASTC10x10UnormSrgb,
        c.WGPUTextureFormat_ASTC12x10UnormSrgb,
        c.WGPUTextureFormat_ASTC12x12UnormSrgb,
        => true,
        else => false,
    };
}

const Buffers = struct {
    uniform_buffer: c.WGPUBuffer,
    rect_vertex: Buffer(Vertex),
    rect_index: Buffer(u16),
    rect_instance: Buffer(Instance),
    masked_rect_instance: Buffer(Instance),
    point_vertex: Buffer(PointVertex),
    line_vertex: Buffer(PointVertex),
    line_index: Buffer(u32),

    pub fn init(device: c.WGPUDevice, queue: c.WGPUQueue) Buffers {
        const uniform_buffer = c.wgpuDeviceCreateBuffer(device, &.{
            .label = "Uniform Buffer",
            .size = @sizeOf(UniformBufferObject),
            .usage = c.WGPUBufferUsage_Uniform | c.WGPUBufferUsage_CopyDst,
        });
        errdefer c.wgpuBufferRelease(uniform_buffer);

        var rect_vertex = Buffer(Vertex).initWithCapacity(device, rect_verts.len, .{
            .label = "Rect Vertex Buffer",
            .usage = c.WGPUBufferUsage_Vertex | c.WGPUBufferUsage_CopyDst,
        });
        errdefer rect_vertex.deinit();

        rect_vertex.write(device, queue, &rect_verts);

        var rect_index = Buffer(u16).initWithCapacity(device, rect_indices.len, .{
            .label = "Rect Index Buffer",
            .usage = c.WGPUBufferUsage_Index | c.WGPUBufferUsage_CopyDst,
        });
        errdefer rect_index.deinit();

        rect_index.write(device, queue, &rect_indices);

        const rect_instance = Buffer(Instance).initWithCapacity(device, 1, .{
            .label = "Rect Instance Buffer",
            .usage = c.WGPUBufferUsage_Vertex | c.WGPUBufferUsage_CopyDst,
        });
        errdefer rect_instance.deinit();

        const masked_rect_instance = Buffer(Instance).initWithCapacity(device, 1, .{
            .label = "Masked Rect Instance Buffer",
            .usage = c.WGPUBufferUsage_Vertex | c.WGPUBufferUsage_CopyDst,
        });
        errdefer masked_rect_instance.deinit();

        const point_vertex = Buffer(PointVertex).initWithCapacity(device, 1, .{
            .label = "Point Vertex Buffer",
            .usage = c.WGPUBufferUsage_Vertex | c.WGPUBufferUsage_CopyDst,
        });
        errdefer point_vertex.deinit();

        const line_vertex = Buffer(PointVertex).initWithCapacity(device, 1, .{
            .label = "Line Vertex Buffer",
            .usage = c.WGPUBufferUsage_Vertex | c.WGPUBufferUsage_CopyDst,
        });
        errdefer line_vertex.deinit();

        const line_index = Buffer(u32).initWithCapacity(device, 1, .{
            .label = "Line Index Buffer",
            .usage = c.WGPUBufferUsage_Index | c.WGPUBufferUsage_CopyDst,
        });
        errdefer line_index.deinit();

        return .{
            .uniform_buffer = uniform_buffer,
            .rect_vertex = rect_vertex,
            .rect_index = rect_index,
            .rect_instance = rect_instance,
            .masked_rect_instance = masked_rect_instance,
            .point_vertex = point_vertex,
            .line_vertex = line_vertex,
            .line_index = line_index,
        };
    }

    pub fn deinit(self: *const @This()) void {
        c.wgpuBufferRelease(self.uniform_buffer);

        self.rect_vertex.deinit();
        self.rect_index.deinit();
        self.rect_instance.deinit();
        self.masked_rect_instance.deinit();
        self.point_vertex.deinit();
        self.line_vertex.deinit();
        self.line_index.deinit();
    }

    pub fn update(self: *@This(), device: c.WGPUDevice, queue: c.WGPUQueue, ubo: *const UniformBufferObject, draw_list: *const DrawList) void {
        c.wgpuQueueWriteBuffer(queue, self.uniform_buffer, 0, ubo, @sizeOf(UniformBufferObject));

        self.rect_instance.write(device, queue, draw_list.rects.items);
        self.masked_rect_instance.write(device, queue, draw_list.masked_rects.items);
        self.point_vertex.write(device, queue, draw_list.point_verts.items);
        self.line_vertex.write(device, queue, draw_list.line_verts.items);
        self.line_index.write(device, queue, draw_list.line_indices.items);
    }
};

fn Buffer(comptime T: type) type {
    return struct {
        handle: c.WGPUBuffer,
        len: u32,
        capacity: u32,
        options: Options,

        pub const Options = struct {
            label: ?[*:0]const u8 = null,
            usage: c.WGPUBufferUsage,
        };

        pub fn init(device: c.WGPUDevice, options: Options) @This() {
            return initWithCapacity(device, 0, options);
        }

        pub fn initWithCapacity(device: c.WGPUDevice, capacity: u32, options: Options) @This() {
            // Allow creating a zero capacity buffer to avoid making handle optional.
            const gpu_size = @max(1, capacity * @sizeOf(T));

            const handle = c.wgpuDeviceCreateBuffer(device, &.{
                .label = options.label,
                .size = gpu_size,
                .usage = options.usage,
            });
            errdefer c.wgpuBufferRelease(handle);

            return .{
                .handle = handle,
                .len = 0,
                .capacity = capacity,
                .options = options,
            };
        }

        pub fn deinit(self: *const @This()) void {
            c.wgpuBufferRelease(self.handle);
        }

        /// Ensures the buffer can hold `capacity` elements of size `T`. Data stored in the buffer is lost if resized.
        pub fn ensureTotalCapacityLossy(self: *@This(), device: c.WGPUDevice, capacity: u32) void {
            if (self.capacity >= capacity) return;
            self.deinit();
            self.* = @This().initWithCapacity(device, capacity, self.options);
        }

        pub fn write(self: *@This(), device: c.WGPUDevice, queue: c.WGPUQueue, items: []const T) void {
            self.ensureTotalCapacityLossy(device, @intCast(items.len));
            c.wgpuQueueWriteBuffer(queue, self.handle, 0, items.ptr, @intCast(items.len * @sizeOf(T)));
            self.len = @intCast(items.len);
        }
    };
}

const Pipelines = struct {
    rect: c.WGPURenderPipeline,
    masked_rect: c.WGPURenderPipeline,
    point: c.WGPURenderPipeline,
    line: c.WGPURenderPipeline,
    bind_group_layout: c.WGPUBindGroupLayout,
    mask_bind_group_layout: c.WGPUBindGroupLayout,

    pub fn init(device: c.WGPUDevice, surface_format: c.WGPUTextureFormat) !Pipelines {
        const shader_code_desc: c.WGPUShaderModuleWGSLDescriptor = .{
            .code = shader_source,
            .chain = .{ .sType = c.WGPUSType_ShaderModuleWGSLDescriptor },
        };

        const shader_desc: c.WGPUShaderModuleDescriptor = .{
            .label = "Main Shader",
            .nextInChain = &shader_code_desc.chain,
        };
        const shader_module = c.wgpuDeviceCreateShaderModule(device, &shader_desc);
        defer c.wgpuShaderModuleRelease(shader_module);

        const uniform_bind_group_layout_entry: c.WGPUBindGroupLayoutEntry = .{
            .binding = 0,
            .visibility = c.WGPUShaderStage_Vertex | c.WGPUShaderStage_Fragment,
            .buffer = .{
                .type = c.WGPUBufferBindingType_Uniform,
                .minBindingSize = @sizeOf(UniformBufferObject),
            },
        };
        const bind_group_layout = c.wgpuDeviceCreateBindGroupLayout(device, &.{
            .label = "UBO Bind Group Layout",
            .entryCount = 1,
            .entries = &uniform_bind_group_layout_entry,
        });
        errdefer c.wgpuBindGroupLayoutRelease(bind_group_layout);

        const mask_bind_group_layout_entries = [_]c.WGPUBindGroupLayoutEntry{
            .{
                .binding = 0,
                .visibility = c.WGPUShaderStage_Fragment,
                .texture = .{
                    .sampleType = c.WGPUTextureSampleType_Float,
                    .viewDimension = c.WGPUTextureViewDimension_2D,
                },
            },
            .{
                .binding = 1,
                .visibility = c.WGPUShaderStage_Fragment,
                .sampler = .{ .type = c.WGPUSamplerBindingType_Filtering },
            },
        };
        const mask_bind_group_layout = c.wgpuDeviceCreateBindGroupLayout(device, &.{
            .label = "Mask Bind Group Layout",
            .entryCount = mask_bind_group_layout_entries.len,
            .entries = &mask_bind_group_layout_entries,
        });
        errdefer c.wgpuBindGroupLayoutRelease(mask_bind_group_layout);

        const rect = createRenderPipeline(
            Vertex,
            Instance,
            device,
            surface_format,
            &[_]c.WGPUBindGroupLayout{bind_group_layout},
            shader_module,
            "vs_triangle_main",
            "fs_main",
            c.WGPUPrimitiveTopology_TriangleList,
        );
        errdefer c.wgpuRenderPipelineRelease(rect);

        const masked_rect = createRenderPipeline(
            Vertex,
            Instance,
            device,
            surface_format,
            &[_]c.WGPUBindGroupLayout{ bind_group_layout, mask_bind_group_layout },
            shader_module,
            "vs_triangle_main",
            "fs_mask_main",
            c.WGPUPrimitiveTopology_TriangleList,
        );
        errdefer c.wgpuRenderPipelineRelease(masked_rect);

        const point = createRenderPipeline(
            PointVertex,
            null,
            device,
            surface_format,
            &[_]c.WGPUBindGroupLayout{bind_group_layout},
            shader_module,
            "vs_point_main",
            "fs_main",
            c.WGPUPrimitiveTopology_PointList,
        );
        errdefer c.wgpuRenderPipelineRelease(point);

        const line = createRenderPipeline(
            PointVertex,
            null,
            device,
            surface_format,
            &[_]c.WGPUBindGroupLayout{bind_group_layout},
            shader_module,
            "vs_point_main",
            "fs_main",
            c.WGPUPrimitiveTopology_LineList,
        );
        errdefer c.wgpuRenderPipelineRelease(line);

        return .{
            .rect = rect,
            .masked_rect = masked_rect,
            .point = point,
            .line = line,
            .bind_group_layout = bind_group_layout,
            .mask_bind_group_layout = mask_bind_group_layout,
        };
    }

    pub fn deinit(self: *const Pipelines) void {
        c.wgpuRenderPipelineRelease(self.rect);
        c.wgpuRenderPipelineRelease(self.masked_rect);
        c.wgpuRenderPipelineRelease(self.point);
        c.wgpuRenderPipelineRelease(self.line);

        c.wgpuBindGroupLayoutRelease(self.mask_bind_group_layout);
        c.wgpuBindGroupLayoutRelease(self.bind_group_layout);
    }
};

fn createRenderPipeline(
    comptime VertexType: type,
    comptime InstanceType: ?type,
    device: c.WGPUDevice,
    surface_format: c.WGPUTextureFormat,
    bind_group_layouts: []const c.WGPUBindGroupLayout,
    shader_module: c.WGPUShaderModule,
    vs_entrypoint: [*:0]const u8,
    fs_entrypoint: [*:0]const u8,
    topology: c.WGPUPrimitiveTopology,
) c.WGPURenderPipeline {
    const blend_state: c.WGPUBlendState = .{
        .color = .{
            .srcFactor = c.WGPUBlendFactor_SrcAlpha,
            .dstFactor = c.WGPUBlendFactor_OneMinusSrcAlpha,
            .operation = c.WGPUBlendOperation_Add,
        },
        .alpha = .{
            .srcFactor = c.WGPUBlendFactor_SrcAlpha,
            .dstFactor = c.WGPUBlendFactor_OneMinusSrcAlpha,
            .operation = c.WGPUBlendOperation_Subtract,
        },
    };

    const color_target: c.WGPUColorTargetState = .{
        .format = surface_format,
        .blend = &blend_state,
        .writeMask = c.WGPUColorWriteMask_All,
    };

    const fragment_state: c.WGPUFragmentState = .{
        .module = shader_module,
        .entryPoint = fs_entrypoint,
        .constantCount = 0,
        .constants = null,
        .targetCount = 1,
        .targets = &color_target,
    };

    comptime var buffers: []const c.WGPUVertexBufferLayout = &.{VertexType.wgpu_buffer_layout};
    if (InstanceType) |I| {
        buffers = buffers ++ &[_]c.WGPUVertexBufferLayout{I.wgpu_buffer_layout};
    }

    const layout = c.wgpuDeviceCreatePipelineLayout(device, &.{
        .label = "Render Pipeline Layout",
        .bindGroupLayoutCount = @intCast(bind_group_layouts.len),
        .bindGroupLayouts = bind_group_layouts.ptr,
    });
    defer c.wgpuPipelineLayoutRelease(layout);

    const desc: c.WGPURenderPipelineDescriptor = .{
        .label = "Render Pipeline",
        .vertex = .{
            .bufferCount = buffers.len,
            .buffers = buffers.ptr,
            .module = shader_module,
            .entryPoint = vs_entrypoint,
            .constantCount = 0,
            .constants = null,
        },
        .fragment = &fragment_state,
        .primitive = .{
            .topology = topology,
            .stripIndexFormat = c.WGPUIndexFormat_Undefined,
            .frontFace = c.WGPUFrontFace_CCW,
            .cullMode = c.WGPUCullMode_Back,
        },
        .depthStencil = null,
        .multisample = .{
            .count = 1,
            .mask = ~@as(u32, 0),
        },
        .layout = layout,
    };

    return c.wgpuDeviceCreateRenderPipeline(device, &desc);
}

const ErrorLogger = struct {
    allocator: Allocator,

    pub fn init(allocator: Allocator) !*@This() {
        const self = try allocator.create(@This());
        self.* = .{ .allocator = allocator };
        return self;
    }

    pub fn deinit(self: *@This()) void {
        self.allocator.destroy(self);
    }

    pub fn logUncapturedDeviceError(self: *@This(), device: c.WGPUDevice) void {
        c.wgpuDeviceSetUncapturedErrorCallback(device, onDeviceError, self);
    }

    pub fn logQueueWorkDone(self: *@This(), queue: c.WGPUQueue) void {
        c.wgpuQueueOnSubmittedWorkDone(queue, onQueueWorkDone, self);
    }

    fn onDeviceError(ty: c.WGPUErrorType, message: [*c]const u8, user_data: ?*anyopaque) callconv(.C) void {
        const self: *@This() = @ptrCast(@alignCast(user_data.?));
        _ = self;

        switch (ty) {
            c.WGPUErrorType_NoError => log.info("No error: {s}", .{message}),
            c.WGPUErrorType_Unknown => log.err("Unknown error: {s}", .{message}),
            c.WGPUErrorType_Force32 => log.err("Force32 error: {s}", .{message}),
            c.WGPUErrorType_Internal => log.err("Internal error: {s}", .{message}),
            c.WGPUErrorType_Validation => log.err("Validation error: {s}", .{message}),
            c.WGPUErrorType_DeviceLost => log.err("Device lost error: {s}", .{message}),
            else => unreachable,
        }
    }

    fn onQueueWorkDone(status: c.WGPUQueueWorkDoneStatus, user_data: ?*anyopaque) callconv(.C) void {
        const self: *@This() = @ptrCast(@alignCast(user_data.?));
        _ = self;

        log.debug("Queue work finished with status: {}", .{status});
    }
};
