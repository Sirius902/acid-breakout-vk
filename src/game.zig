const std = @import("std");

pub const Game = struct {
    /// The ratio of the current frame time over the target frame time.
    dt: f64,
    avg_frametime_s: f64,

    pub const target_frametime = 1.0 / 60.0 * std.time.ns_per_s;

    pub fn init() !Game {
        return .{
            .dt = 1.0,
            .avg_frametime_s = target_frametime * std.time.ns_per_s,
        };
    }

    pub fn deinit(self: *Game) void {
        _ = self;
    }

    /// Simulates one tick of the game.
    ///
    /// `frametime` is the time from the last tick to this tick in nanoseconds.
    pub fn tick(self: *Game, frametime: u64) !void {
        const frametime_flt = @as(f64, @floatFromInt(frametime));
        self.dt = frametime_flt / target_frametime;

        const alpha = 0.8;
        const frametime_s = frametime_flt / std.time.ns_per_s;
        self.avg_frametime_s = alpha * frametime_s + (1 - alpha) * self.avg_frametime_s;
    }

    /// Returns the average frames per second the game is ticking at.
    pub fn averageFps(self: *const Game) f64 {
        return 1.0 / self.avg_frametime_s;
    }
};
