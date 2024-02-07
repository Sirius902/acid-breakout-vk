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
    const pixels = game.game_arena.allocator().alloc(PixelState, game.size.x * game.size.y) catch |err|
        std.debug.panic("Failed to alloc strip pixels: {}", .{err});
    @memset(pixels, .present);

    return .{
        .rect = .{ .min = vec2(0, 0.75 * game_size.y), .max = game_size },
        .pixels = pixels,
    };
}

pub fn tick(self: *Self, game: *Game) void {
    _ = self;
    _ = game;
}

pub fn draw(self: *const Self, game: *const Game, draw_list: *DrawList) DrawList.Error!void {
    // TODO: Mask rect with texture.
    _ = game;
    try draw_list.addRect(.{
        .min = self.rect.min,
        .max = self.rect.max,
        .shading = .{ .rainbow = .{} },
    });

    // const min = math.vec2Cast(u32, math.vec2Round(self.rect.min));
    // const max = math.vec2Cast(u32, math.vec2Round(self.rect.max));
    // for (min.y..max.y) |y| {
    //     for (min.x..max.x) |x| {
    //         if (self.pixels[game.size.x * (y - min.y) + (x - min.x)] == .missing) continue;
    //
    //         const game_x = @as(f32, @floatFromInt(x)) / @as(f32, @floatFromInt(game.size.x));
    //         const color = @import("../color.zig").lrgbFromHsv(@import("zlm").vec3(game_x * @import("zlm").toRadians(360.0), 1, 1));
    //
    //         try draw_list.addPoint(.{
    //             .pos = vec2(@floatFromInt(x), @floatFromInt(y)),
    //             .shading = .{ .color = @import("zlm").vec4(color.x, color.y, color.z, 1) },
    //         });
    //     }
    // }
}

pub fn notifyCollision(self: *Self, game: *Game, pos: Vec2) bool {
    const rounded_pos = math.vec2Round(pos);
    const int_pos = math.vec2Cast(u32, rounded_pos.sub(self.rect.min));
    const index = game.size.x * int_pos.y + int_pos.x;

    switch (self.pixels[index]) {
        .present => {
            self.pixels[index] = .missing;
            game.spawnBall(.{ .start_pos = rounded_pos });
            game.playSound(&assets.ball_free);
            return true;
        },
        .missing => return false,
    }
}
