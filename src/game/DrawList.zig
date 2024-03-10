const std = @import("std");
const c = @import("../c.zig");
const vk = @import("vulkan");
const zlm = @import("zlm");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const Vec2 = zlm.Vec2;
const Vec3 = zlm.Vec3;
const Vec4 = zlm.Vec4;
const vec3 = zlm.vec3;
const log = std.log.scoped(.draw);

const Self = @This();

arena: ArenaAllocator,
rects: std.ArrayList(Instance),
masked_rects: std.ArrayList(Instance),
rect_masks: std.ArrayList(Mask),
point_verts: std.ArrayList(PointVertex),
line_verts: std.ArrayList(PointVertex),
line_indices: std.ArrayList(u32),
current_path: std.ArrayList(PointVertex),
is_path_started: bool = false,

pub const Error = error{
    PathNotStarted,
    PathAlreadyStarted,
} || Allocator.Error;

pub const ShadingMethod = enum(u32) {
    color = 0,
    rainbow = 1,
    rainbow_scroll = 2,
};

pub const Instance = struct {
    model: zlm.Mat4,
    color: Vec4,
    shading: ShadingMethod,

    pub const binding = 1;

    pub const binding_description = vk.VertexInputBindingDescription{
        .binding = binding,
        .stride = @sizeOf(Instance),
        .input_rate = .instance,
    };

    pub const attribute_description = [_]vk.VertexInputAttributeDescription{
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

    pub const wgpu_buffer_layout = c.WGPUVertexBufferLayout{
        .arrayStride = @sizeOf(Instance),
        .stepMode = c.WGPUVertexStepMode_Instance,
        .attributeCount = wgpu_attributes.len,
        .attributes = &wgpu_attributes,
    };

    pub const wgpu_attributes = [_]c.WGPUVertexAttribute{
        .{
            .shaderLocation = 2,
            .format = c.WGPUVertexFormat_Float32x4,
            .offset = @offsetOf(Instance, "model") + 0 * @sizeOf(zlm.Vec4),
        },
        .{
            .shaderLocation = 3,
            .format = c.WGPUVertexFormat_Float32x4,
            .offset = @offsetOf(Instance, "model") + 1 * @sizeOf(zlm.Vec4),
        },
        .{
            .shaderLocation = 4,
            .format = c.WGPUVertexFormat_Float32x4,
            .offset = @offsetOf(Instance, "model") + 2 * @sizeOf(zlm.Vec4),
        },
        .{
            .shaderLocation = 5,
            .format = c.WGPUVertexFormat_Float32x4,
            .offset = @offsetOf(Instance, "model") + 3 * @sizeOf(zlm.Vec4),
        },
        .{
            .shaderLocation = 6,
            .format = c.WGPUVertexFormat_Float32x4,
            .offset = @offsetOf(Instance, "color"),
        },
        .{
            .shaderLocation = 7,
            .format = c.WGPUVertexFormat_Uint32,
            .offset = @offsetOf(Instance, "shading"),
        },
    };
};

pub const PointVertex = struct {
    pos: Vec2,
    color: Vec4,
    shading: ShadingMethod,

    pub const binding = 0;

    pub const binding_description = vk.VertexInputBindingDescription{
        .binding = binding,
        .stride = @sizeOf(PointVertex),
        .input_rate = .vertex,
    };

    pub const attribute_description = [_]vk.VertexInputAttributeDescription{
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

    pub const wgpu_buffer_layout = c.WGPUVertexBufferLayout{
        .arrayStride = @sizeOf(PointVertex),
        .stepMode = c.WGPUVertexStepMode_Vertex,
        .attributeCount = wgpu_attributes.len,
        .attributes = &wgpu_attributes,
    };

    pub const wgpu_attributes = [_]c.WGPUVertexAttribute{
        .{
            .shaderLocation = 0,
            .format = c.WGPUVertexFormat_Float32x2,
            .offset = @offsetOf(PointVertex, "pos"),
        },
        .{
            .shaderLocation = 1,
            .format = c.WGPUVertexFormat_Float32x4,
            .offset = @offsetOf(PointVertex, "color"),
        },
        .{
            .shaderLocation = 2,
            .format = c.WGPUVertexFormat_Uint32,
            .offset = @offsetOf(PointVertex, "shading"),
        },
    };
};

pub const Alpha = struct {
    a: f32 = 1,
};

pub const Shading = union(ShadingMethod) {
    color: Vec4,
    rainbow: Alpha,
    rainbow_scroll: Alpha,
};

pub const Mask = struct {
    width: u32,
    height: u32,
    pixels: []const u8,
};

pub const Rect = struct {
    min: Vec2,
    max: Vec2,
    shading: Shading,
    mask: ?Mask = null,

    pub fn center(self: Rect) Vec2 {
        return self.min.add(self.max).scale(0.5);
    }

    pub fn size(self: Rect) Vec2 {
        return self.max.sub(self.min);
    }
};

pub const Point = struct {
    pos: Vec2,
    shading: Shading,
};

pub const Path = struct {
    points: []const Point,
};

pub fn init(allocator: Allocator) Self {
    return .{
        .arena = ArenaAllocator.init(allocator),
        .rects = std.ArrayList(Instance).init(allocator),
        .masked_rects = std.ArrayList(Instance).init(allocator),
        .rect_masks = std.ArrayList(Mask).init(allocator),
        .point_verts = std.ArrayList(PointVertex).init(allocator),
        .line_verts = std.ArrayList(PointVertex).init(allocator),
        .line_indices = std.ArrayList(u32).init(allocator),
        .current_path = std.ArrayList(PointVertex).init(allocator),
    };
}

pub fn deinit(self: *Self) void {
    self.arena.deinit();
    self.rects.deinit();
    self.masked_rects.deinit();
    self.rect_masks.deinit();
    self.point_verts.deinit();
    self.line_verts.deinit();
    self.line_indices.deinit();
    self.current_path.deinit();
}

pub fn clear(self: *Self) void {
    _ = self.arena.reset(.retain_capacity);

    self.rects.clearRetainingCapacity();
    self.masked_rects.clearRetainingCapacity();
    self.rect_masks.clearRetainingCapacity();
    self.point_verts.clearRetainingCapacity();
    self.line_verts.clearRetainingCapacity();
    self.line_indices.clearRetainingCapacity();
    self.current_path.clearRetainingCapacity();

    self.is_path_started = false;
}

pub fn addRect(self: *Self, rect: Rect) Error!void {
    std.debug.assert(rect.min.x <= rect.max.x and rect.min.y <= rect.max.y);

    const size = rect.size();
    const model = zlm.Mat4.createScale(size.x, size.y, 1)
        .mul(zlm.Mat4.createTranslation(vec3(rect.min.x, rect.min.y, 0)));

    var color: Vec4 = undefined;
    switch (rect.shading) {
        .color => |cl| color = cl,
        inline else => |alpha| color.w = alpha.a,
    }

    const instance: Instance = .{
        .model = model,
        .color = color,
        .shading = rect.shading,
    };

    if (rect.mask) |mask| {
        try self.masked_rects.append(instance);
        try self.rect_masks.append(mask);
    } else {
        try self.rects.append(instance);
    }
}

pub fn addPoint(self: *Self, point: Point) Error!void {
    var color: Vec4 = undefined;
    switch (point.shading) {
        .color => |cl| color = cl,
        inline else => |alpha| color.w = alpha.a,
    }

    if (self.is_path_started) {
        try self.current_path.append(.{
            .pos = point.pos,
            .color = color,
            .shading = point.shading,
        });
    } else {
        try self.point_verts.append(.{
            .pos = point.pos,
            .color = color,
            .shading = point.shading,
        });
    }
}

pub fn beginPath(self: *Self) Error!void {
    if (self.is_path_started) return error.PathAlreadyStarted;
    self.is_path_started = true;
    self.current_path.clearRetainingCapacity();
}

pub fn endPath(self: *Self) Error!void {
    if (!self.is_path_started) return error.PathNotStarted;
    self.is_path_started = false;

    const path_start = self.line_verts.items.len;
    try self.line_verts.appendSlice(self.current_path.items);

    if (self.current_path.items.len == 1) {
        try self.line_indices.appendSlice(&[_]u32{ @intCast(path_start), @intCast(path_start) });
    } else {
        for (0..self.current_path.items.len - 1) |i| {
            try self.line_indices.appendSlice(&[_]u32{ @intCast(path_start + i), @intCast(path_start + i + 1) });
        }
    }
}

pub fn dupe(self: *Self, comptime T: type, m: []const T) Error![]T {
    return self.arena.allocator().dupe(T, m);
}
