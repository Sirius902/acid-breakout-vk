const std = @import("std");
const zlm = @import("zlm");
const AtomicSwapper = @import("util.zig").AtomicSwapper;

mouse_state: AtomicSwapper(MouseState),
keyboard_state: AtomicSwapper(KeyboardState),

const Self = @This();

pub fn init() Self {
    var keyboard_state: KeyboardState = .{};
    for (std.enums.values(Key)) |key| {
        keyboard_state.put(key, .release);
    }

    return .{
        .mouse_state = AtomicSwapper(MouseState).init(.{}),
        .keyboard_state = AtomicSwapper(KeyboardState).init(keyboard_state),
    };
}

pub fn mouseState(self: *const Self) MouseState {
    return self.mouse_state.frontConst(.Acquire).*;
}

pub fn keyState(self: *const Self, key: Key) KeyState {
    return self.keyboard_state.frontConst(.Acquire).getAssertContains(key);
}

/// Must be called while no other invocation of `updateMouse` is in progress.
pub fn updateMouse(self: *Self, pos: zlm.Vec2) void {
    const back = self.mouse_state.back(.Unordered);
    if (back.pos) |p| back.delta = pos.sub(p);
    back.pos = pos;

    self.mouse_state.swap(.Release);
    self.mouse_state.back(.Unordered).* = self.mouse_state.front(.Unordered).*;
}

/// Must be called while no other invocation of `updateKey` is in progress.
pub fn updateKey(self: *Self, key: Key, state: KeyState) void {
    const key_state = self.keyboard_state.back(.Unordered).getPtrAssertContains(key);
    key_state.* = state;

    self.keyboard_state.swap(.Release);
    self.keyboard_state.back(.Unordered).* = self.keyboard_state.front(.Unordered).*;
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
