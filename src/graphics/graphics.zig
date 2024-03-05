const zlm = @import("zlm");
const vk = @import("vulkan");

pub const rect_verts = [_]Vertex{
    .{ .pos = zlm.Vec2.zero, .uv = zlm.Vec2.zero },
    .{ .pos = zlm.Vec2.one, .uv = zlm.Vec2.one },
    .{ .pos = zlm.vec2(0, 1), .uv = zlm.vec2(0, 1) },
    .{ .pos = zlm.vec2(1, 0), .uv = zlm.vec2(1, 0) },
};

pub const rect_indices = [_]u16{ 0, 1, 2, 0, 3, 1 };

pub const Vertex = struct {
    pos: zlm.Vec2,
    uv: zlm.Vec2,

    pub const binding = 0;

    pub const binding_description = vk.VertexInputBindingDescription{
        .binding = binding,
        .stride = @sizeOf(Vertex),
        .input_rate = .vertex,
    };

    pub const attribute_description = [_]vk.VertexInputAttributeDescription{
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

pub const PushConstants = extern struct {
    view: zlm.Mat4,
    aspect: zlm.Vec2,
    viewport_size: zlm.Vec2,
    time: f32,
};
