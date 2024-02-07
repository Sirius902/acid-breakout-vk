const std = @import("std");
const zlm = @import("zlm");
const Allocator = std.mem.Allocator;
const AtomicSwapper = @import("util.zig").AtomicSwapper;

mouse_state: AtomicSwapper(MouseState),
keyboard_state: AtomicSwapper(KeyboardState),

const Self = @This();

pub fn init(allocator: Allocator) !Self {
    var keyboard_state: KeyboardState = .{};
    for (std.enums.values(Key)) |key| {
        keyboard_state.put(key, .release);
    }

    return .{
        .mouse_state = try AtomicSwapper(MouseState).init(allocator, .{}),
        .keyboard_state = try AtomicSwapper(KeyboardState).init(allocator, keyboard_state),
    };
}

pub fn deinit(self: *Self) void {
    self.mouse_state.deinit();
    self.keyboard_state.deinit();
}

pub fn mouseState(self: *Self) MouseState {
    const state = self.mouse_state.acquireFront();
    defer self.mouse_state.release(state);
    return state.*;
}

pub fn keyState(self: *Self, key: Key) KeyState {
    const state = self.keyboard_state.acquireFront();
    defer self.keyboard_state.release(state);
    return state.getAssertContains(key);
}

pub fn updateMouse(self: *Self, pos: zlm.Vec2) !void {
    const ref = blk: {
        const prev_data = self.mouse_state.acquireFront();
        defer self.mouse_state.release(prev_data);

        const ref = try self.mouse_state.createRef();
        ref.data = prev_data.*;
        break :blk ref;
    };
    defer self.mouse_state.swapFront(ref);

    if (ref.data.pos) |p| ref.data.delta = pos.sub(p);
    ref.data.pos = pos;
}

pub fn updateKey(self: *Self, key: Key, state: KeyState) !void {
    const ref = blk: {
        const prev_data = self.keyboard_state.acquireFront();
        defer self.keyboard_state.release(prev_data);

        const ref = try self.keyboard_state.createRef();
        ref.data = prev_data.*;
        break :blk ref;
    };
    defer self.keyboard_state.swapFront(ref);
    const data = &ref.data;

    const key_state = data.getPtrAssertContains(key);
    key_state.* = state;
}

pub const MouseState = struct {
    pos: ?zlm.Vec2 = null,
    delta: zlm.Vec2 = zlm.Vec2.zero,
};

pub const Key = enum {
    f1,
    escape,
};

pub const KeyboardState = std.EnumMap(Key, KeyState);

pub const KeyState = enum {
    press,
    release,
    repeat,

    pub fn isDown(self: KeyState) bool {
        return self == .press or self == .repeat;
    }
};
