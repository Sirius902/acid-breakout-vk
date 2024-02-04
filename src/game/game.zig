const std = @import("std");
const assets = @import("assets");
const math = @import("../math.zig");
const Sound = assets.Sound;
const Paddle = @import("Paddle.zig");
const Ball = @import("Ball.zig");
const Vec2i = math.Vec2i;
const Vec2u = math.Vec2u;
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;

const Prng = std.rand.DefaultPrng;

pub const log = std.log.scoped(.game);

pub const DrawList = @import("DrawList.zig");

pub const TickResult = struct {
    sound_list: []*const Sound.Hash,
};

pub const Game = struct {
    allocator: Allocator,
    tick_arena: ArenaAllocator,
    /// The time elapsed from the previous tick to the current tick in seconds.
    dt: f32,
    avg_dt: f64,
    // TODO: Gamepad input.
    /// Last known mouse position within the game window.
    mouse_pos: ?Vec2u,
    /// The number of units the player's cursor changed since the last tick.
    cursor_delta: Vec2i,
    size: Vec2u,
    paddle: Paddle,
    // TODO: Allocate balls in arena?
    balls: BallList,
    sound_list: std.ArrayList(*const Sound.Hash),
    prng: Prng,

    pub const target_dt = 1.0 / 60.0 * std.time.ns_per_s;

    const BallList = std.DoublyLinkedList(Ball);

    pub fn init(size: Vec2u, allocator: Allocator) !Game {
        var self: Game = .{
            .allocator = allocator,
            .tick_arena = ArenaAllocator.init(allocator),
            .dt = @as(f32, target_dt) / std.time.ns_per_s,
            .avg_dt = @as(f64, target_dt) / std.time.ns_per_s,
            .mouse_pos = null,
            .cursor_delta = Vec2i.zero,
            .size = size,
            .paddle = undefined,
            .balls = .{},
            .sound_list = std.ArrayList(*const Sound.Hash).init(allocator),
            .prng = Prng.init(0xDEADBEEFC0FFEE),
        };
        self.paddle = Paddle.init(&self);

        const ball_node = try allocator.create(BallList.Node);
        errdefer allocator.destroy(ball_node);
        ball_node.data = Ball.init(&self, true);
        self.balls.append(ball_node);

        return self;
    }

    pub fn deinit(self: *Game) void {
        self.tick_arena.deinit();
        self.sound_list.deinit();

        while (self.balls.pop()) |node| self.allocator.destroy(node);
        self.paddle.deinit(self);
    }

    /// Simulates one tick of the game.
    ///
    /// `ticktime` is the time from the last tick to this tick in nanoseconds.
    pub fn tick(self: *Game, ticktime: u64) TickResult {
        _ = self.tick_arena.reset(.retain_capacity);
        self.sound_list.clearRetainingCapacity();

        const ticktime_f = @as(f64, @floatFromInt(ticktime));
        self.dt = @floatCast(ticktime_f / std.time.ns_per_s);

        const alpha = 0.2;
        self.avg_dt = alpha * self.dt + (1 - alpha) * self.avg_dt;

        self.paddle.tick(self);

        var ball_node = self.balls.first;
        while (ball_node) |n| {
            const next = n.next;
            defer ball_node = next;

            var ball = &n.data;
            ball.tick(self);
        }

        return .{ .sound_list = self.sound_list.items };
    }

    pub fn draw(self: *const Game, draw_list: *DrawList) DrawList.Error!void {
        var ball_node = self.balls.first;
        while (ball_node) |n| {
            const next = n.next;
            defer ball_node = next;

            var ball = &n.data;
            try ball.draw(self, draw_list);
        }

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

    pub fn random(self: *Game) std.rand.Random {
        return self.prng.random();
    }

    /// Returns the game's average ticks per second.
    pub fn averageTps(self: *const Game) f64 {
        return 1.0 / self.avg_dt;
    }
};
