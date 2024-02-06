const std = @import("std");
const AtomicOrder = std.builtin.AtomicOrder;

pub fn AtomicSwapper(comptime T: type) type {
    return struct {
        items: [2]T,
        index: std.atomic.Value(u8),

        const Self = @This();

        pub fn init(t: T) Self {
            return .{
                .items = [_]T{ t, t },
                .index = std.atomic.Value(u8).init(0),
            };
        }

        pub fn swap(self: *Self, comptime order: AtomicOrder) void {
            _ = self.index.bitToggle(0, order);
        }

        pub fn front(self: *Self, comptime order: AtomicOrder) *T {
            return &self.items[self.index.load(order)];
        }

        pub fn back(self: *Self, comptime order: AtomicOrder) *T {
            return &self.items[self.index.load(order) ^ 1];
        }

        pub fn frontConst(self: *const Self, comptime order: AtomicOrder) *const T {
            return &self.items[self.index.load(order)];
        }

        pub fn backConst(self: *const Self, comptime order: AtomicOrder) *const T {
            return &self.items[self.index.load(order) ^ 1];
        }
    };
}
