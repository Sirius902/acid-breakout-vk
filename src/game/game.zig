const std = @import("std");
const math = @import("../math.zig");
const Paddle = @import("Paddle.zig");
const Vec2i = math.Vec2i;
const Vec2u = math.Vec2u;

pub const Game = struct {
    /// The ratio of the current frame time over the target frame time.
    dt: f64,
    avg_ticktime_s: f64,
    // TODO: Gamepad input.
    /// Last known mouse position within the game window.
    mouse_pos: ?Vec2u,
    /// The number of units the player's cursor changed since the last tick.
    cursor_delta: Vec2i,
    size: Vec2u,
    paddle: Paddle,

    pub const target_ticktime = 1.0 / 60.0 * std.time.ns_per_s;

    pub fn init(size: Vec2u) !Game {
        var self: Game = .{
            .dt = 1.0,
            .avg_ticktime_s = @as(f64, target_ticktime) / std.time.ns_per_s,
            .mouse_pos = null,
            .cursor_delta = Vec2i.zero,
            .size = size,
            .paddle = undefined,
        };
        self.paddle = Paddle.init(&self);

        return self;
    }

    pub fn deinit(self: *Game) void {
        self.paddle.deinit(self);
    }

    /// Simulates one tick of the game.
    ///
    /// `ticktime` is the time from the last tick to this tick in nanoseconds.
    pub fn tick(self: *Game, ticktime: u64) !void {
        const ticktime_flt = @as(f64, @floatFromInt(ticktime));
        self.dt = ticktime_flt / target_ticktime;

        const alpha = 0.2;
        const ticktime_s = ticktime_flt / std.time.ns_per_s;
        self.avg_ticktime_s = alpha * ticktime_s + (1 - alpha) * self.avg_ticktime_s;

        self.paddle.tick(self);
    }

    pub fn updateInput(self: *Game, mouse_pos: ?Vec2u) void {
        self.cursor_delta = blk: {
            if (self.mouse_pos) |prev_pos| {
                if (mouse_pos) |pos| {
                    break :blk math.vec2Cast(i32, pos).sub(math.vec2Cast(i32, prev_pos));
                }
            }
            break :blk Vec2i.zero;
        };

        if (mouse_pos) |pos| {
            self.mouse_pos = pos;
        }
    }

    /// Returns the game's average ticks per second.
    pub fn averageTps(self: *const Game) f64 {
        return 1.0 / self.avg_ticktime_s;
    }
};
