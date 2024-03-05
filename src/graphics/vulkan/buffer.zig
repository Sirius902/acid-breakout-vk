const std = @import("std");
const vk = @import("vulkan");
const GraphicsContext = @import("graphics_context.zig").GraphicsContext;

pub fn Buffer(comptime T: type) type {
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
