const std = @import("std");
const c = @import("../../c.zig");
const Game = @import("../../game/game.zig").Game;
const DrawList = @import("../../game/game.zig").DrawList;
const Allocator = std.mem.Allocator;

allocator: Allocator,
window: *c.GLFWwindow,
wait_for_vsync: bool,
is_graphics_outdated: bool = false,

const Self = @This();

const log = std.log.scoped(.gfx);

pub fn init(
    allocator: Allocator,
    window: *c.GLFWwindow,
    app_name: [*:0]const u8,
    wait_for_vsync: bool,
) !Self {
    _ = app_name;

    var desc = c.WGPUInstanceDescriptor{};
    desc.nextInChain = null;

    const instance = c.wgpuCreateInstance(&desc);
    _ = instance;

    return .{
        .allocator = allocator,
        .window = window,
        .wait_for_vsync = wait_for_vsync,
    };
}

pub fn deinit(self: *Self) void {
    _ = self;
}

pub fn renderFrame(self: *Self, game: *const Game, draw_list: *const DrawList) !void {
    _ = self;
    _ = game;
    _ = draw_list;
}

pub fn igImplNewFrame() void {
    // TODO: Uncomment.
    // c.ImGui_ImplWGPU_NewFrame();
}
