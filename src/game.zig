const std = @import("std");

pub const Game = struct {
    /// The ratio of the current frame time over the target frame time.
    dt: f64,
    avg_ticktime_s: f64,

    pub const target_ticktime = 1.0 / 60.0 * std.time.ns_per_s;

    pub fn init() !Game {
        return .{
            .dt = 1.0,
            .avg_ticktime_s = @as(f64, target_ticktime) / std.time.ns_per_s,
        };
    }

    pub fn deinit(self: *Game) void {
        _ = self;
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
    }

    /// Returns the game's average ticks per second.
    pub fn averageTps(self: *const Game) f64 {
        return 1.0 / self.avg_ticktime_s;
    }
};
