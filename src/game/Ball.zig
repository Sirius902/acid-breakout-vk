const std = @import("std");
const assets = @import("assets");
const zlm = @import("zlm");
const math = @import("../math.zig");
const Game = @import("game.zig").Game;
const DrawList = @import("game.zig").DrawList;
const Vec2 = zlm.Vec2;
const vec2 = zlm.vec2;
const Vec2i = math.Vec2i;
const vec2i = math.vec2i;
const Vec2u = math.Vec2u;
const vec2u = math.vec2u;

const Self = @This();

pos: Vec2,
vel: Vec2,
delay: f32,
history_timer: f32,
pos_history: PosHistory,
pos_history_nodes: [history_max_len]PosHistory.Node,
is_hit: bool,
marked_for_delete: bool,

const PosHistory = std.DoublyLinkedList(Vec2);

const gravity = 1.25;
const size = vec2(1, 1);
const history_max_len = 8;
const history_interval = @as(f32, 0.25) / history_max_len;

pub fn init(game: *Game, is_first: bool) Self {
    return .{
        .pos = math.vec2Cast(f32, game.size).scale(0.5),
        .vel = if (is_first) Vec2.zero else vec2(16 * 2 * (game.random().float(f32) - 0.5), 0),
        .delay = 1,
        .history_timer = 0,
        .pos_history = .{},
        .pos_history_nodes = undefined,
        .is_hit = false,
        .marked_for_delete = false,
    };
}

pub fn deinit(self: *Self, game: *Game) void {
    _ = self;
    _ = game;
}

pub fn tick(self: *Self, game: *Game) void {
    if (self.delay > 0) {
        self.delay = @max(0, self.delay - game.dt);
        return;
    }

    if (self.history_timer > 0) {
        self.history_timer = @max(0, self.history_timer - game.dt);
    } else {
        self.updateHistory();
        self.history_timer = history_interval;
    }

    if (!self.is_hit) self.vel.y -= gravity;
    self.handleCollisions(game);

    if (!self.isVisible(game)) self.marked_for_delete = true;
}

pub fn draw(self: *const Self, game: *const Game, draw_list: *DrawList) DrawList.Error!void {
    _ = game;

    var pos_history_node = self.pos_history.first;
    while (pos_history_node) |node| {
        const next = node.next;
        defer pos_history_node = next;

        try draw_list.addPoint(.{ .pos = node.data });
    }

    try draw_list.addPoint(.{ .pos = self.pos });
}

fn isVisible(self: *const Self, game: *const Game) bool {
    const game_rect = game.rect();
    const rect = math.Rect.fromCenter(self.pos, size);
    if (rect.overlaps(game_rect)) return true;

    var node = self.pos_history.first;
    while (node) |n| {
        const next = n.next;
        defer node = next;

        const history_rect = math.Rect.fromCenter(n.data, size);
        if (history_rect.overlaps(game_rect)) return true;
    }

    return false;
}

fn handleCollisions(self: *Self, game: *Game) void {
    const target_pos = self.pos.add(self.vel.scale(game.dt));
    const target_rect = math.Rect.fromCenter(target_pos, size);
    const paddle_rect = game.paddle.rect(game);

    if (target_rect.overlaps(paddle_rect)) {
        game.playSound(&assets.ball_reflect);

        var speed = self.vel.length();
        if (!self.is_hit) {
            self.is_hit = true;
            speed *= @sqrt(2.0);
        }

        self.vel.x = self.pos.x - game.paddle.center_x;
        self.vel.y *= -1;
        self.vel = self.vel.normalize().scale(speed);

        self.pos = self.pos.add(self.vel.scale(game.dt));
        return;
    }

    const game_rect = game.rect();
    if (!target_rect.overlaps(game_rect)) {
        var is_collision = false;
        if (target_rect.max.y > game_rect.max.y) {
            is_collision = true;
            self.vel.y *= -1;
        }

        if (target_rect.min.x < game_rect.min.x or target_rect.max.x > game_rect.max.x) {
            is_collision = true;
            self.vel.x *= -1;
        }

        if (is_collision) game.playSound(&assets.ball_reflect);
        self.pos = self.pos.add(self.vel.scale(game.dt));
        return;
    }

    self.pos = target_pos;
}

fn updateHistory(self: *Self) void {
    const history_node = if (self.pos_history.len < self.pos_history_nodes.len)
        &self.pos_history_nodes[self.pos_history.len]
    else
        self.pos_history.pop() orelse unreachable;

    history_node.data = self.pos;
    self.pos_history.prepend(history_node);
}
