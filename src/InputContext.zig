const std = @import("std");
const zlm = @import("zlm");

mouse_state: MouseState,
keyboard_state: KeyboardState,

const Self = @This();

pub fn init() Self {
    var keyboard_state: KeyboardState = .{};
    inline for (comptime std.enums.values(Key)) |key| {
        keyboard_state.put(key, .release);
    }

    return .{
        .mouse_state = .{},
        .keyboard_state = keyboard_state,
    };
}

pub fn mouseState(self: *const Self) MouseState {
    return self.mouse_state;
}

pub fn keyState(self: *const Self, key: Key) KeyState {
    return self.keyboard_state.getAssertContains(key);
}

pub fn updateMouse(self: *Self, pos: zlm.Vec2) void {
    if (self.mouse_state.pos) |p| self.mouse_state.delta = pos.sub(p);
    self.mouse_state.pos = pos;
}

pub fn updateKey(self: *Self, key: Key, state: KeyState) void {
    const key_state = self.keyboard_state.getPtrAssertContains(key);
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
