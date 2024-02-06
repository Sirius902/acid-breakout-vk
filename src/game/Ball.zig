const std = @import("std");
const assets = @import("assets");
const zlm = @import("zlm");
const color = @import("../color.zig");
const math = @import("../math.zig");
const Game = @import("game.zig").Game;
const DrawList = @import("game.zig").DrawList;
const Vec2 = zlm.Vec2;
const Vec3 = zlm.Vec3;
const vec2 = zlm.vec2;
const vec3 = zlm.vec3;
const vec4 = zlm.vec4;
const Vec2i = math.Vec2i;
const vec2i = math.vec2i;
const Vec2u = math.Vec2u;
const vec2u = math.vec2u;

const Self = @This();

pos: Vec2,
vel: Vec2,
color: Vec3,
delay: f32,
history_timer: f32,
pos_history: PosHistory,
pos_history_nodes: [history_max_len]PosHistory.Node,
is_hit: bool,
marked_for_delete: bool,

pub const SpawnParams = struct {
    start_pos: ?Vec2 = null,
    random_x_vel: bool = true,
    delay: f32 = 0,
};

const PosHistory = std.DoublyLinkedList(Vec2);

const gravity = 60;
const size = vec2(1, 1);
const history_max_len = 8;
const history_interval = @as(f32, 0.25) / history_max_len;

pub fn spawn(game: *Game, params: SpawnParams) Self {
    const pos = if (params.start_pos) |p| p else math.vec2Cast(f32, game.size).scale(0.5);
    return .{
        .pos = pos,
        .vel = if (params.random_x_vel) vec2(16 * 2 * (game.random().float(f32) - 0.5), 0) else Vec2.zero,
        .color = colorAtPos(game, pos),
        .delay = params.delay,
        .history_timer = 0,
        .pos_history = .{},
        .pos_history_nodes = undefined,
        .is_hit = false,
        .marked_for_delete = false,
    };
}

pub fn tick(self: *Self, game: *Game) void {
    if (self.delay > 0) {
        self.delay = @max(0, self.delay - game.dt);
        return;
    }

    if (!self.is_hit) self.vel.y -= gravity * game.dt;
    self.pos = self.pos.add(self.vel.scale(game.dt));

    if (self.handleCollision(game)) |collision_pos| {
        self.updateHistory(collision_pos);
    }

    if (self.history_timer > 0) {
        self.history_timer = @max(0, self.history_timer - game.dt);
    } else {
        self.updateHistory(self.pos);
        self.history_timer = history_interval;
    }

    if (!self.isVisible(game)) self.marked_for_delete = true;
}

pub fn draw(self: *const Self, game: *const Game, draw_list: *DrawList) DrawList.Error!void {
    _ = game;

    const r = self.color.x;
    const g = self.color.y;
    const b = self.color.z;

    {
        if (self.is_hit) {
            try draw_list.beginPath();
            try draw_list.addPoint(.{ .pos = self.pos, .shading = .{ .color = vec4(r, g, b, 1) } });
        }
        defer if (self.is_hit) draw_list.endPath() catch {};

        var i: usize = 0;
        var pos_history_node = self.pos_history.first;
        while (pos_history_node) |node| : (i += 1) {
            const next = node.next;
            defer pos_history_node = next;

            const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(@max(1, self.pos_history.len - 1)));
            const alpha = 1.0 - t;
            try draw_list.addPoint(.{ .pos = node.data, .shading = .{ .color = vec4(r, g, b, alpha) } });
        }
    }

    try draw_list.addPoint(.{ .pos = self.pos, .shading = .{ .color = vec4(r, g, b, 1) } });
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

fn handleCollision(self: *Self, game: *Game) ?Vec2 {
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
        return target_pos;
    }

    if (self.is_hit and target_rect.overlaps(game.strip.rect)) {
        game.strip.notifyCollision(game, target_pos);
        self.vel.y *= -1;
        return target_pos;
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
        return target_pos;
    }

    return null;
}

fn updateHistory(self: *Self, pos: Vec2) void {
    const history_node = if (self.pos_history.len < self.pos_history_nodes.len)
        &self.pos_history_nodes[self.pos_history.len]
    else
        self.pos_history.pop() orelse unreachable;

    history_node.data = pos;
    self.pos_history.prepend(history_node);
}

fn colorAtPos(game: *const Game, pos: Vec2) Vec3 {
    const game_x = pos.x / @as(f32, @floatFromInt(game.size.x));
    return color.lrgbFromHsv(vec3(game_x * zlm.toRadians(360.0), 1, 1));
}
