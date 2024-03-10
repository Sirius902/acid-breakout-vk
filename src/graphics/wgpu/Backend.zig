const std = @import("std");
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
swapchain_format: c.WGPUTextureFormat,
surface_extent: Extent2D,
swapchain: c.WGPUSwapChain,
pipelines: Pipelines,
buffers: Buffers,
uniform_bind_group: c.WGPUBindGroup,
window: *c.GLFWwindow,
wait_for_vsync: bool,
is_graphics_outdated: bool = false,

const Self = @This();

const log = std.log.scoped(.gfx);
const shader_source = @embedFile("shaders/shader.wgsl");
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
};

pub fn init(
    allocator: Allocator,
    window: *c.GLFWwindow,
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

    const surface = c.glfwGetWGPUSurface(instance, window);
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

    const swapchain_format = c.wgpuSurfaceGetPreferredFormat(surface, adapter);

    const surface_extent = getSurfaceExtent(window);
    const swapchain = recreateSwapchain(device, surface, surface_extent, swapchain_format, wait_for_vsync);
    errdefer c.wgpuSwapChainRelease(swapchain);

    const pipelines = try Pipelines.init(device, swapchain_format);
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

    if (!c.ImGui_ImplGlfw_InitForOther(window, true)) return error.ImGuiGlfwInit;
    // TODO: Check if ImGui colors are correct.
    if (!c.ImGui_ImplWGPU_Init(device, 1, swapchain_format, c.WGPUTextureFormat_Undefined)) return error.ImGuiWGPUInit;
    errdefer c.ImGui_ImplWGPU_Shutdown();

    return .{
        .allocator = allocator,
        .instance = instance,
        .adapter = adapter,
        .surface = surface,
        .device = device,
        .error_logger = error_logger,
        .queue = queue,
        .swapchain_format = swapchain_format,
        .surface_extent = surface_extent,
        .swapchain = swapchain,
        .pipelines = pipelines,
        .buffers = buffers,
        .uniform_bind_group = uniform_bind_group,
        .window = window,
        .wait_for_vsync = wait_for_vsync,
    };
}

pub fn deinit(self: *Self) void {
    c.ImGui_ImplWGPU_Shutdown();
    c.wgpuBindGroupRelease(self.uniform_bind_group);
    self.buffers.deinit();
    self.pipelines.deinit();
    c.wgpuSwapChainRelease(self.swapchain);
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
        const old_swapchain = self.swapchain;
        self.swapchain = recreateSwapchain(
            self.device,
            self.surface,
            current_surface_extent,
            self.swapchain_format,
            self.wait_for_vsync,
        );
        self.surface_extent = current_surface_extent;
        c.wgpuSwapChainRelease(old_swapchain);
        self.is_graphics_outdated = false;
    }

    var encoder_desc: c.WGPUCommandEncoderDescriptor = .{ .label = "Render Command Encoder" };
    const encoder = c.wgpuDeviceCreateCommandEncoder(self.device, &encoder_desc);
    defer c.wgpuCommandEncoderRelease(encoder);

    const next_texture = c.wgpuSwapChainGetCurrentTextureView(self.swapchain) orelse {
        log.err("Failed to acquire next swap chain texture", .{});
        return error.SwapchainTextureAcquire;
    };
    defer c.wgpuTextureViewRelease(next_texture);

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

    // TODO: Pixel mask.
    if (self.buffers.masked_rect_instance.len > 0) {
        c.wgpuRenderPassEncoderSetPipeline(render_pass, self.pipelines.masked_rect);
        c.wgpuRenderPassEncoderSetVertexBuffer(render_pass, 1, self.buffers.masked_rect_instance.handle, 0, @sizeOf(Instance) * @as(u64, self.buffers.masked_rect_instance.len));
        c.wgpuRenderPassEncoderDrawIndexed(render_pass, self.buffers.rect_index.len, self.buffers.masked_rect_instance.len, 0, 0, 0);
    }

    // TODO: ImGui color correction.
    if (c.igGetDrawData()) |ig_draw_data| {
        c.ImGui_ImplWGPU_RenderDrawData(ig_draw_data, render_pass);
    }

    c.wgpuRenderPassEncoderEnd(render_pass);
    c.wgpuRenderPassEncoderRelease(render_pass);

    const cmdbuf_desc: c.WGPUCommandBufferDescriptor = .{ .label = "Render Command Buffer" };
    const cmdbuf = c.wgpuCommandEncoderFinish(encoder, &cmdbuf_desc);
    defer c.wgpuCommandBufferRelease(cmdbuf);

    c.wgpuQueueSubmit(self.queue, 1, &cmdbuf);

    c.wgpuSwapChainPresent(self.swapchain);
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

fn getSurfaceExtent(window: *c.GLFWwindow) Extent2D {
    var fw: c_int = undefined;
    var fh: c_int = undefined;
    c.glfwGetFramebufferSize(window, &fw, &fh);

    return .{ .width = @intCast(fw), .height = @intCast(fh) };
}

fn recreateSwapchain(
    device: c.WGPUDevice,
    surface: c.WGPUSurface,
    surface_extent: Extent2D,
    swapchain_format: c.WGPUTextureFormat,
    wait_for_vsync: bool,
) c.WGPUSwapChain {
    var swapchain_desc: c.WGPUSwapChainDescriptor = .{
        .label = "Main Swapchain",
        .width = surface_extent.width,
        .height = surface_extent.height,
        .format = swapchain_format,
        .usage = c.WGPUTextureUsage_RenderAttachment,
        .presentMode = if (wait_for_vsync) c.WGPUPresentMode_Fifo else c.WGPUPresentMode_Mailbox,
    };
    return c.wgpuDeviceCreateSwapChain(device, surface, &swapchain_desc);
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

    pub fn init(device: c.WGPUDevice, swapchain_format: c.WGPUTextureFormat) !Pipelines {
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

        const bind_group_layout_entry: c.WGPUBindGroupLayoutEntry = .{
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
            .entries = &bind_group_layout_entry,
        });
        errdefer c.wgpuBindGroupLayoutRelease(bind_group_layout);

        const rect = createRenderPipeline(
            Vertex,
            Instance,
            device,
            swapchain_format,
            bind_group_layout,
            shader_module,
            "vs_triangle_main",
            c.WGPUPrimitiveTopology_TriangleList,
        );
        errdefer c.wgpuRenderPipelineRelease(rect);

        // TODO: Make this different somehow or merge it with rect if no difference is needed.
        const masked_rect = createRenderPipeline(
            Vertex,
            Instance,
            device,
            swapchain_format,
            bind_group_layout,
            shader_module,
            "vs_triangle_main",
            c.WGPUPrimitiveTopology_TriangleList,
        );
        errdefer c.wgpuRenderPipelineRelease(masked_rect);

        const point = createRenderPipeline(
            PointVertex,
            null,
            device,
            swapchain_format,
            bind_group_layout,
            shader_module,
            "vs_point_main",
            c.WGPUPrimitiveTopology_PointList,
        );
        errdefer c.wgpuRenderPipelineRelease(point);

        const line = createRenderPipeline(
            PointVertex,
            null,
            device,
            swapchain_format,
            bind_group_layout,
            shader_module,
            "vs_point_main",
            c.WGPUPrimitiveTopology_LineList,
        );
        errdefer c.wgpuRenderPipelineRelease(line);

        return .{
            .rect = rect,
            .masked_rect = masked_rect,
            .point = point,
            .line = line,
            .bind_group_layout = bind_group_layout,
        };
    }

    pub fn deinit(self: *const Pipelines) void {
        c.wgpuRenderPipelineRelease(self.rect);
        c.wgpuRenderPipelineRelease(self.masked_rect);
        c.wgpuRenderPipelineRelease(self.point);
        c.wgpuRenderPipelineRelease(self.line);

        c.wgpuBindGroupLayoutRelease(self.bind_group_layout);
    }
};

fn createRenderPipeline(
    comptime VertexType: type,
    comptime InstanceType: ?type,
    device: c.WGPUDevice,
    swapchain_format: c.WGPUTextureFormat,
    bind_group_layout: c.WGPUBindGroupLayout,
    shader_module: c.WGPUShaderModule,
    vs_entrypoint: [*:0]const u8,
    topology: c.WGPUPrimitiveTopology,
) c.WGPURenderPipeline {
    // TODO: Make sure blend state is the same as Vulkan.
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
        .format = swapchain_format,
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

    comptime var buffers: []const c.WGPUVertexBufferLayout = &.{VertexType.wgpu_buffer_layout};
    if (InstanceType) |I| {
        buffers = buffers ++ &[_]c.WGPUVertexBufferLayout{I.wgpu_buffer_layout};
    }

    const layout = c.wgpuDeviceCreatePipelineLayout(device, &.{
        .label = "Render Pipeline Layout",
        .bindGroupLayoutCount = 1,
        .bindGroupLayouts = &bind_group_layout,
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
            .alphaToCoverageEnabled = false,
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
