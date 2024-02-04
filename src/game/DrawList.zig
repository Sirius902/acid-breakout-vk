const std = @import("std");
const zlm = @import("zlm");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const Vec2 = zlm.Vec2;
const Vec3 = zlm.Vec3;
const log = std.log.scoped(.draw);

const Self = @This();

allocator: Allocator,
arena: ArenaAllocator,
rects: std.ArrayList(Rect),
points: std.ArrayList(Point),
paths: std.ArrayList(Path),
path_buf: std.ArrayList(Point),
is_path_started: bool = false,

pub const Error = error{
    PathNotStarted,
    PathAlreadyStarted,
} || Allocator.Error;

pub const Rect = struct {
    min: Vec2,
    max: Vec2,
};

pub const Point = struct {
    pos: Vec2,
};

pub const Path = struct {
    points: []const Point,
};

pub fn init(allocator: Allocator) Self {
    return .{
        .allocator = allocator,
        .arena = ArenaAllocator.init(allocator),
        .rects = std.ArrayList(Rect).init(allocator),
        .points = std.ArrayList(Point).init(allocator),
        .paths = std.ArrayList(Path).init(allocator),
        .path_buf = std.ArrayList(Point).init(allocator),
    };
}

pub fn deinit(self: *Self) void {
    self.arena.deinit();
    self.path_buf.deinit();
    self.rects.deinit();
    self.points.deinit();
    self.paths.deinit();
}

pub fn clear(self: *Self) void {
    _ = self.arena.reset(.retain_capacity);

    if (self.is_path_started) {
        log.warn("Expected path to end", .{});

        self.is_path_started = false;
        self.path_buf.clearRetainingCapacity();
    }

    self.rects.clearRetainingCapacity();
    self.points.clearRetainingCapacity();
    self.paths.clearRetainingCapacity();
}

pub fn addRect(self: *Self, rect: Rect) Error!void {
    std.debug.assert(rect.min.x <= rect.max.x and rect.min.y <= rect.max.y);
    try self.rects.append(rect);
}

pub fn addPoint(self: *Self, point: Point) Error!void {
    if (self.is_path_started) {
        try self.path_buf.append(point);
    } else {
        try self.points.append(point);
    }
}

pub fn beginPath(self: *Self) Error!void {
    if (self.is_path_started) return error.PathAlreadyStarted;
    self.is_path_started = true;
}

pub fn endPath(self: *Self) Error!void {
    if (!self.is_path_started) return error.PathNotStarted;
    self.is_path_started = false;

    const points = try self.arena.allocator().dupe(Point, self.path_buf.items);
    try self.paths.append(.{ .points = points });
    self.path_buf.clearRetainingCapacity();
}
