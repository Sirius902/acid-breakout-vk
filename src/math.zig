const zlm = @import("zlm");

const signed = zlm.SpecializeOn(i32);
const unsigned = zlm.SpecializeOn(u32);

pub const Line = struct {
    from: zlm.Vec2,
    to: zlm.Vec2,

    pub fn new(from: zlm.Vec2, to: zlm.Vec2) Line {
        return .{ .from = from, .to = to };
    }
};

pub const Rect = struct {
    min: zlm.Vec2,
    max: zlm.Vec2,

    pub fn new(min: zlm.Vec2, max: zlm.Vec2) Rect {
        return .{ .min = min, .max = max };
    }

    pub fn fromCenter(center: zlm.Vec2, size: zlm.Vec2) Rect {
        const half_size = size.scale(0.5);
        return .{ .min = center.sub(half_size), .max = center.add(half_size) };
    }

    pub fn contains(self: Rect, pos: zlm.Vec2) bool {
        return self.min.x < pos.x and self.max.x > pos.x and self.min.y < pos.y and self.max.y > pos.y;
    }

    pub fn overlaps(self: Rect, other: Rect) bool {
        return self.min.x < other.max.x and self.max.x > other.min.x and self.max.y > other.min.y and self.min.y < other.max.y;
    }

    pub fn sides(self: Rect) [4]Line {
        return .{
            line(zlm.vec2(self.min.x, self.max.y), zlm.vec2(self.max.x, self.max.y)),
            line(zlm.vec2(self.min.x, self.min.y), zlm.vec2(self.min.x, self.max.y)),
            line(zlm.vec2(self.max.x, self.min.y), zlm.vec2(self.max.x, self.max.y)),
            line(zlm.vec2(self.min.x, self.min.y), zlm.vec2(self.max.x, self.min.y)),
        };
    }
};

pub const line = Line.new;
pub const rect = Rect.new;

pub const Vec2i = signed.Vec2;
pub const vec2i = signed.vec2;
pub const Vec2u = unsigned.Vec2;
pub const vec2u = unsigned.vec2;

pub fn vec2Cast(comptime Real: type, vec: anytype) zlm.SpecializeOn(Real).Vec2 {
    const ResultVec = comptime zlm.SpecializeOn(Real).Vec2;
    const SrcReal = @TypeOf(vec.x);
    return switch (@typeInfo(Real)) {
        .Int => switch (@typeInfo(SrcReal)) {
            .Int => ResultVec.new(@intCast(vec.x), @intCast(vec.y)),
            .Float => ResultVec.new(@intFromFloat(vec.x), @intFromFloat(vec.y)),
            else => @compileError("Expected vec's Real to be either .Int or .Float"),
        },
        .Float => switch (@typeInfo(SrcReal)) {
            .Int => ResultVec.new(@floatFromInt(vec.x), @floatFromInt(vec.y)),
            .Float => ResultVec.new(@as(Real, vec.x), @as(Real, vec.y)),
            else => @compileError("Expected vec's Real to be either .Int or .Float"),
        },
        else => @compileError("Expected Real to be either .Int or .Float"),
    };
}

pub fn vec2Round(vec: anytype) @TypeOf(vec) {
    return @TypeOf(vec).new(@round(vec.x), @round(vec.y));
}
