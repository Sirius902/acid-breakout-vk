const std = @import("std");
const assets = @import("assets");
const zlm = @import("zlm");
const math = @import("../math.zig");
const Game = @import("game.zig").Game;
const DrawList = @import("game.zig").DrawList;
const Vec2 = zlm.Vec2;
const vec2 = zlm.vec2;
const Vec2u = math.Vec2u;

const Self = @This();

center_x: f32,
game_relative_size: Vec2,
was_touching_bounds: bool = false,

// TODO: Move this to a common file.
const Rect = struct {
    min: Vec2,
    max: Vec2,
};

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

    const is_touching_bounds = self.isTouchingBounds(game);
    if (is_touching_bounds and !self.was_touching_bounds) {
        game.playSound(&assets.ball_reflect);
    }
    self.was_touching_bounds = is_touching_bounds;
}

pub fn draw(self: *const Self, game: *const Game, draw_list: *DrawList) DrawList.Error!void {
    const r = self.rect(game);
    try draw_list.addRect(.{ .min = r.min, .max = r.max });
}

fn size(self: *const Self, game: *const Game) Vec2u {
    const size_f = math.vec2Cast(f32, game.size).mul(self.game_relative_size);
    return math.vec2Cast(u32, math.vec2Round(size_f));
}

fn center(self: *const Self, game: *const Game) Vec2 {
    return vec2(self.center_x, centerY(game));
}

fn rect(self: *const Self, game: *const Game) Rect {
    const size_f = math.vec2Cast(f32, self.size(game));
    const center_y = centerY(game);
    return .{
        .min = vec2(self.center_x - size_f.x * 0.5, center_y - size_f.y * 0.5),
        .max = vec2(self.center_x + size_f.x * 0.5, center_y + size_f.y * 0.5),
    };
}

fn moveInBounds(self: *Self, game: *const Game) void {
    const size_x: f32 = @floatFromInt(self.size(game).x);
    self.center_x = std.math.clamp(
        self.center_x,
        0.5 * size_x,
        @as(f32, @floatFromInt(game.size.x)) - 0.5 * size_x,
    );
}

fn isTouchingBounds(self: *const Self, game: *const Game) bool {
    const r = self.rect(game);
    return r.min.x < 1 or r.max.x + 1 >= @as(f32, @floatFromInt(game.size.x));
}

fn centerY(game: *const Game) f32 {
    return @as(f32, @floatFromInt(game.size.y)) * 0.05;
}
