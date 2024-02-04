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

const PosHistory = std.DoublyLinkedList(Vec2);

const gravity = 1;
const size = vec2(1, 1);
const history_max_len = 16;
const history_interval = @as(f32, 1) / history_max_len;

pub fn init(game: *Game, is_first: bool) Self {
    return .{
        .pos = math.vec2Cast(f32, game.size).scale(0.5),
        .vel = if (is_first) Vec2.zero else vec2(16 * 2 * (game.random().float(f32) - 0.5), 0),
        .delay = 1,
        .history_timer = 0,
        .pos_history = .{},
        .pos_history_nodes = undefined,
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
        self.history_timer -= game.dt;
    } else {
        self.updateHistory();
        self.history_timer = history_interval;
    }

    self.vel.y -= gravity;
    self.pos = self.pos.add(self.vel.scale(game.dt));
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

fn updateHistory(self: *Self) void {
    const history_node = if (self.pos_history.len < self.pos_history_nodes.len)
        &self.pos_history_nodes[self.pos_history.len]
    else
        self.pos_history.pop() orelse unreachable;

    history_node.data = self.pos;
    self.pos_history.prepend(history_node);
}
