const std = @import("std");
const c = @import("../../c.zig");
const Game = @import("../../game/game.zig").Game;
const DrawList = @import("../../game/game.zig").DrawList;
const Allocator = std.mem.Allocator;

allocator: Allocator,
instance: c.WGPUInstance,
adapter: c.WGPUAdapter,
surface: c.WGPUSurface,
device: c.WGPUDevice,
error_logger: *ErrorLogger,
queue: c.WGPUQueue,
texture_format: c.WGPUTextureFormat,
surface_extent: Extent2D,
swapchain: c.WGPUSwapChain,
window: *c.GLFWwindow,
wait_for_vsync: bool,
is_graphics_outdated: bool = false,

const Self = @This();

const log = std.log.scoped(.gfx);

const Extent2D = struct {
    width: u32,
    height: u32,

    pub fn eql(self: @This(), other: @This()) bool {
        return self.width == other.width and self.height == other.height;
    }
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

    error_logger.logQueueWorkDone(queue);

    const texture_format = c.wgpuSurfaceGetPreferredFormat(surface, adapter);

    const surface_extent = getSurfaceExtent(window);
    const swapchain = recreateSwapchain(device, surface, surface_extent, texture_format, wait_for_vsync);
    errdefer c.wgpuSwapChainRelease(swapchain);

    if (!c.ImGui_ImplGlfw_InitForOther(window, true)) return error.ImGuiGlfwInit;
    // TODO: Depth format?
    if (!c.ImGui_ImplWGPU_Init(device, 1, texture_format, 0)) return error.ImGuiWGPUInit;
    errdefer c.ImGui_ImplWGPU_Shutdown();

    return .{
        .allocator = allocator,
        .instance = instance,
        .adapter = adapter,
        .surface = surface,
        .device = device,
        .error_logger = error_logger,
        .queue = queue,
        .texture_format = texture_format,
        .surface_extent = surface_extent,
        .swapchain = swapchain,
        .window = window,
        .wait_for_vsync = wait_for_vsync,
    };
}

pub fn deinit(self: *Self) void {
    c.ImGui_ImplWGPU_Shutdown();
    c.wgpuSwapChainRelease(self.swapchain);
    self.error_logger.deinit();
    c.wgpuQueueRelease(self.queue);
    c.wgpuDeviceRelease(self.device);
    c.wgpuSurfaceRelease(self.surface);
    c.wgpuAdapterRelease(self.adapter);
    c.wgpuInstanceRelease(self.instance);
}

pub fn renderFrame(self: *Self, game: *const Game, draw_list: *const DrawList) !void {
    _ = game;
    _ = draw_list;

    const current_surface_extent = getSurfaceExtent(self.window);
    if (self.is_graphics_outdated or !self.surface_extent.eql(current_surface_extent)) {
        const old_swapchain = self.swapchain;
        self.swapchain = recreateSwapchain(
            self.device,
            self.surface,
            current_surface_extent,
            self.texture_format,
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
    texture_format: c.WGPUTextureFormat,
    wait_for_vsync: bool,
) c.WGPUSwapChain {
    var swapchain_desc: c.WGPUSwapChainDescriptor = .{
        .label = "Main Swapchain",
        .width = surface_extent.width,
        .height = surface_extent.height,
        .format = texture_format,
        .usage = c.WGPUTextureUsage_RenderAttachment,
        .presentMode = if (wait_for_vsync) c.WGPUPresentMode_Fifo else c.WGPUPresentMode_Mailbox,
    };
    return c.wgpuDeviceCreateSwapChain(device, surface, &swapchain_desc);
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
