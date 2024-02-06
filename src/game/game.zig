const std = @import("std");
const assets = @import("assets");
const zlm = @import("zlm");
const math = @import("../math.zig");
const Sound = assets.Sound;
const Paddle = @import("Paddle.zig");
const Strip = @import("Strip.zig");
const Ball = @import("Ball.zig");
const Vec2 = @import("zlm").Vec2;
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
    ball_arena: ArenaAllocator,
    /// The time elapsed from the previous tick to the current tick in seconds.
    dt: f32,
    time: f32,
    avg_dt: f64,
    // TODO: Gamepad input.
    /// Last known mouse position within the game window.
    mouse_pos: ?Vec2,
    /// The number of units the player's cursor changed since the last tick.
    cursor_delta: Vec2,
    size: Vec2u,
    paddle: Paddle,
    strip: Strip,
    // TODO: Allocate balls in arena?
    balls: BallList,
    free_balls: BallList,
    sound_list: std.ArrayList(*const Sound.Hash),
    prng: Prng,

    pub const target_dt = 1.0 / 60.0;
    pub const max_dt = 1.0 / 4.0;

    const BallList = std.DoublyLinkedList(Ball);

    pub fn init(size: Vec2u, allocator: Allocator) !Game {
        const ball_arena = ArenaAllocator.init(allocator);
        var self: Game = .{
            .allocator = allocator,
            .tick_arena = ArenaAllocator.init(allocator),
            .ball_arena = ball_arena,
            .dt = target_dt,
            .time = 0,
            .avg_dt = target_dt,
            .mouse_pos = null,
            .cursor_delta = Vec2.zero,
            .size = size,
            .paddle = undefined,
            .strip = undefined,
            .balls = .{},
            .free_balls = .{},
            .sound_list = std.ArrayList(*const Sound.Hash).init(allocator),
            .prng = Prng.init(0xDEADBEEFC0FFEE),
        };
        self.paddle = Paddle.spawn(&self);
        self.strip = Strip.spawn(&self);
        self.spawnBall(.{ .random_x_vel = false, .delay = 1 });

        return self;
    }

    pub fn deinit(self: *Game) void {
        self.tick_arena.deinit();
        self.ball_arena.deinit();
        self.sound_list.deinit();
    }

    /// Simulates one tick of the game.
    ///
    /// `ticktime` is the time from the last tick to this tick in nanoseconds.
    pub fn tick(self: *Game, ticktime: u64) TickResult {
        _ = self.tick_arena.reset(.retain_capacity);
        self.sound_list.clearRetainingCapacity();

        const ticktime_s: f32 = @floatCast(@as(f64, @floatFromInt(ticktime)) / std.time.ns_per_s);
        self.dt = @min(ticktime_s, max_dt);
        self.time += ticktime_s;

        const alpha = 0.2;
        self.avg_dt = alpha * self.dt + (1 - alpha) * self.avg_dt;

        self.paddle.tick(self);

        var ball_node = self.balls.first;
        while (ball_node) |n| {
            const next = n.next;
            defer ball_node = next;

            var ball = &n.data;
            ball.tick(self);
            if (ball.marked_for_delete) {
                self.balls.remove(n);
                self.free_balls.append(n);
            }
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

        try self.strip.draw(self, draw_list);
        try self.paddle.draw(self, draw_list);
    }

    pub fn updateInput(self: *Game, mouse_pos: ?Vec2) void {
        self.cursor_delta = blk: {
            if (self.mouse_pos) |prev_pos| {
                if (mouse_pos) |pos| {
                    break :blk pos.sub(prev_pos);
                }
            }
            break :blk Vec2.zero;
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

    pub fn spawnBall(self: *Game, params: Ball.SpawnParams) void {
        const node = self.free_balls.pop() orelse self.ball_arena.allocator().create(BallList.Node) catch |err| {
            log.err("Failed to alloc ball node: {}", .{err});
            return;
        };

        const ball = &node.data;
        ball.* = Ball.spawn(self, params);
        self.balls.append(node);
    }

    pub fn rect(self: *const Game) math.Rect {
        return .{ .min = Vec2.zero, .max = math.vec2Cast(f32, self.size) };
    }

    pub fn random(self: *Game) std.rand.Random {
        return self.prng.random();
    }

    /// Returns the game's average ticks per second.
    pub fn averageTps(self: *const Game) f64 {
        return 1.0 / self.avg_dt;
    }
};
