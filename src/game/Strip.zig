const assets = @import("assets");
const math = @import("../math.zig");
const DrawList = @import("game.zig").DrawList;
const Game = @import("game.zig").Game;
const Ball = @import("Ball.zig");
const Rect = math.Rect;
const Vec2 = @import("zlm").Vec2;
const vec2 = @import("zlm").vec2;

rect: Rect,

const Self = @This();

pub fn spawn(game: *Game) Self {
    const game_size = math.vec2Cast(f32, game.size);
    return .{ .rect = .{
        .min = vec2(0, 0.75 * game_size.y),
        .max = game_size,
    } };
}

pub fn tick(self: *Self, game: *Game) void {
    _ = self;
    _ = game;
}

pub fn draw(self: *const Self, game: *const Game, draw_list: *DrawList) DrawList.Error!void {
    _ = game;
    try draw_list.addRect(.{
        .min = self.rect.min,
        .max = self.rect.max,
        .shading = .{ .rainbow = .{} },
    });
}

// TODO: Add method to spawn entity on `Game`.
pub fn notifyCollision(self: *Self, game: *Game, pos: Vec2) void {
    _ = self;
    const rounded_pos = math.vec2Round(pos);
    const ball_node = game.allocator.create(@import("std").DoublyLinkedList(Ball).Node) catch |err| {
        @import("std").log.err("Failed to spawn ball: {}", .{err});
        return;
    };

    game.playSound(&assets.ball_free);

    const ball = &ball_node.data;
    ball.* = Ball.spawn(game, .{});
    ball.pos = rounded_pos;
    game.balls.append(ball_node);
}
