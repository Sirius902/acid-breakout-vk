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

pub fn spawn(game: *Game) Self {
    return .{
        .center_x = @as(f32, @floatFromInt(game.size.x)) * 0.5,
        .game_relative_size = vec2(0.225, 0.025),
    };
}

pub fn tick(self: *Self, game: *Game) void {
    if (game.cursor_delta.length() > 0) {
        if (game.mouse_pos) |pos| {
            self.center_x = pos.x;
        }
    }

    self.moveInBounds(game);
}

pub fn draw(self: *const Self, game: *const Game, draw_list: *DrawList) DrawList.Error!void {
    const r = self.rect(game);
    try draw_list.addRect(.{
        .min = r.min,
        .max = r.max,
        .shading = .{ .rainbow_scroll = .{} },
    });
}

pub fn rect(self: *const Self, game: *const Game) math.Rect {
    const size_f = math.vec2Cast(f32, self.size(game));
    return math.Rect.fromCenter(vec2(self.center_x, centerY(game)), size_f);
}

pub fn center(self: *const Self, game: *const Game) Vec2 {
    return vec2(self.center_x, centerY(game));
}

fn size(self: *const Self, game: *const Game) Vec2u {
    const size_f = math.vec2Cast(f32, game.size).mul(self.game_relative_size);
    return math.vec2Cast(u32, math.vec2Round(size_f));
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
