const std = @import("std");
const assets = @import("assets");
const math = @import("../math.zig");
const DrawList = @import("game.zig").DrawList;
const Game = @import("game.zig").Game;
const Ball = @import("Ball.zig");
const Rect = math.Rect;
const Vec2 = @import("zlm").Vec2;
const vec2 = @import("zlm").vec2;

rect: Rect,
pixels: []PixelState,

const Self = @This();

pub const PixelState = enum(u8) {
    missing = 0x00,
    present = 0xFF,
};

pub fn spawn(game: *Game) Self {
    const game_size = math.vec2Cast(f32, game.size);
    const rect: Rect = .{ .min = vec2(0, 0.75 * game_size.y), .max = game_size };
    const pixels = game.game_arena.allocator().alloc(PixelState, game.size.x * height(rect)) catch |err|
        std.debug.panic("Failed to alloc strip pixels: {}", .{err});
    @memset(pixels, .present);

    return .{
        .rect = rect,
        .pixels = pixels,
    };
}

pub fn tick(self: *Self, game: *Game) void {
    _ = self;
    _ = game;
}

pub fn draw(self: *const Self, game: *const Game, draw_list: *DrawList) DrawList.Error!void {
    try draw_list.addRect(.{
        .min = self.rect.min,
        .max = self.rect.max,
        .shading = .{ .rainbow = .{} },
        .mask = .{
            .width = game.size.x,
            .height = height(self.rect),
            .pixels = try draw_list.dupe(u8, @as([*]const u8, @ptrCast(self.pixels.ptr))[0..self.pixels.len]),
        },
    });
}

pub fn notifyCollision(self: *Self, game: *Game, pos: Vec2) bool {
    const grid_pos = vec2(@trunc(pos.x), @trunc(pos.y));
    const int_pos = math.vec2Cast(u32, grid_pos.sub(self.rect.min));
    const index = game.size.x * int_pos.y + int_pos.x;

    switch (self.pixels[index]) {
        .present => {
            self.pixels[index] = .missing;
            game.spawnBall(.{ .start_pos = grid_pos });
            game.playSound(&assets.ball_free);
            return true;
        },
        .missing => return false,
    }
}

pub fn numPixelsRemaining(self: *const Self) usize {
    return std.mem.count(PixelState, self.pixels, &[_]PixelState{.present});
}

pub fn numTotalPixels(self: *const Self) usize {
    return self.pixels.len;
}

fn height(rect: Rect) u32 {
    return @intFromFloat(@floor(rect.max.y - rect.min.y));
}
