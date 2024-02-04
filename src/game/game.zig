const std = @import("std");
const assets = @import("assets");
const math = @import("../math.zig");
const Sound = assets.Sound;
const Paddle = @import("Paddle.zig");
const Vec2i = math.Vec2i;
const Vec2u = math.Vec2u;
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;

pub const log = std.log.scoped(.game);

pub const DrawList = @import("DrawList.zig");

pub const TickResult = struct {
    sound_list: []*const Sound.Hash,
};

pub const Game = struct {
    allocator: Allocator,
    tick_arena: ArenaAllocator,
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
    sound_list: std.ArrayList(*const Sound.Hash),

    pub const target_ticktime = 1.0 / 60.0 * std.time.ns_per_s;

    pub fn init(size: Vec2u, allocator: Allocator) Game {
        var self: Game = .{
            .allocator = allocator,
            .tick_arena = ArenaAllocator.init(allocator),
            .dt = 1.0,
            .avg_ticktime_s = @as(f64, target_ticktime) / std.time.ns_per_s,
            .mouse_pos = null,
            .cursor_delta = Vec2i.zero,
            .size = size,
            .paddle = undefined,
            .sound_list = std.ArrayList(*const Sound.Hash).init(allocator),
        };
        self.paddle = Paddle.init(&self);

        return self;
    }

    pub fn deinit(self: *Game) void {
        self.tick_arena.deinit();
        self.sound_list.deinit();
        self.paddle.deinit(self);
    }

    /// Simulates one tick of the game.
    ///
    /// `ticktime` is the time from the last tick to this tick in nanoseconds.
    pub fn tick(self: *Game, ticktime: u64) TickResult {
        _ = self.tick_arena.reset(.retain_capacity);
        self.sound_list.clearRetainingCapacity();

        const ticktime_flt = @as(f64, @floatFromInt(ticktime));
        self.dt = ticktime_flt / target_ticktime;

        const alpha = 0.2;
        const ticktime_s = ticktime_flt / std.time.ns_per_s;
        self.avg_ticktime_s = alpha * ticktime_s + (1 - alpha) * self.avg_ticktime_s;

        self.paddle.tick(self);

        return .{ .sound_list = self.sound_list.items };
    }

    pub fn draw(self: *const Game, draw_list: *DrawList) DrawList.Error!void {
        try self.paddle.draw(self, draw_list);
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

    pub fn playSound(self: *Game, sound: *const Sound) void {
        self.sound_list.append(&sound.hash) catch |err| {
            log.err("Failure adding to sound list: {}", .{err});
        };
    }

    /// Returns the game's average ticks per second.
    pub fn averageTps(self: *const Game) f64 {
        return 1.0 / self.avg_ticktime_s;
    }
};
