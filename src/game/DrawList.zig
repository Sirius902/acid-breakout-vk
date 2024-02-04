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
lines: std.ArrayList(Line),
line_buf: std.ArrayList(Point),
is_line_started: bool = false,

pub const Error = error{
    LineNotStarted,
    LineAlreadyStarted,
} || Allocator.Error;

pub const Rect = struct {
    min: Vec2,
    max: Vec2,
};

pub const Point = struct {
    pos: Vec2,
};

pub const Line = struct {
    points: []const Point,
};

pub fn init(allocator: Allocator) Self {
    return .{
        .allocator = allocator,
        .arena = ArenaAllocator.init(allocator),
        .rects = std.ArrayList(Rect).init(allocator),
        .points = std.ArrayList(Point).init(allocator),
        .lines = std.ArrayList(Line).init(allocator),
        .line_buf = std.ArrayList(Point).init(allocator),
    };
}

pub fn deinit(self: *Self) void {
    self.arena.deinit();
    self.line_buf.deinit();
    self.rects.deinit();
    self.points.deinit();
    self.lines.deinit();
}

pub fn clear(self: *Self) void {
    _ = self.arena.reset(.retain_capacity);

    if (self.is_line_started) {
        log.warn("Expected line to end", .{});

        self.is_line_started = false;
        self.line_buf.clearRetainingCapacity();
    }

    self.rects.clearRetainingCapacity();
    self.points.clearRetainingCapacity();
    self.lines.clearRetainingCapacity();
}

pub fn addRect(self: *Self, rect: Rect) Error!void {
    std.debug.assert(rect.min.x <= rect.max.x and rect.min.y <= rect.max.y);
    try self.rects.append(rect);
}

pub fn addPoint(self: *Self, point: Point) Error!void {
    if (self.is_line_started) {
        try self.line_buf.append(point);
    } else {
        try self.points.append(point);
    }
}

pub fn beginLine(self: *Self) Error!void {
    if (self.is_line_started) return error.LineAlreadyStarted;
    self.is_line_started = true;
}

pub fn endLine(self: *Self) Error!void {
    if (!self.is_line_started) return error.LineNotStarted;
    self.is_line_started = false;

    const points = try self.arena.allocator().dupe(Point, self.line_buf.items);
    try self.lines.append(.{ .points = points });
    self.line_buf.clearRetainingCapacity();
}
