const std = @import("std");
const zlm = @import("zlm");
const math = @import("../math.zig");
const Game = @import("game.zig").Game;
const Vec2 = zlm.Vec2;
const vec2 = zlm.vec2;
const Vec2i = math.Vec2i;
const vec2i = math.vec2i;
const Vec2u = math.Vec2u;
const vec2u = math.vec2u;

center_x: f32,
game_relative_size: Vec2,

const Self = @This();

pub fn init(game: *Game) Self {
    return .{
        .center_x = @as(f32, @floatFromInt(game.size.x)) * 0.5,
        .game_relative_size = vec2(0.225, 0.025),
    };
}

pub fn deinit(self: *Self, game: *Game) void {
    _ = self;
    _ = game;
}

pub fn tick(self: *Self, game: *Game) void {
    if (game.mouse_pos) |pos| {
        self.center_x = @floatFromInt(pos.x);
    }
    self.moveInBounds(game);

    std.log.debug("paddle: center={}, size={}", .{ self.center(game), self.size(game) });
}

fn size(self: *const Self, game: *const Game) Vec2u {
    const size_f = math.vec2Cast(f32, game.size).mul(self.game_relative_size);
    return math.vec2Cast(u32, math.vec2Round(size_f));
}

fn center(self: *const Self, game: *const Game) Vec2 {
    return vec2(self.center_x, centerY(game));
}

fn moveInBounds(self: *Self, game: *const Game) void {
    const size_x = self.size(game).x;
    self.center_x = std.math.clamp(
        self.center_x,
        @as(f32, @floatFromInt(size_x)),
        @as(f32, @floatFromInt(game.size.x - size_x)),
    );
}

fn centerY(game: *const Game) f32 {
    return @as(f32, @floatFromInt(game.size.y)) * 0.05;
}
