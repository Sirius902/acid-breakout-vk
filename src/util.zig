const std = @import("std");
const Allocator = std.mem.Allocator;
const MemoryPool = std.heap.MemoryPool;
const AtomicOrder = std.builtin.AtomicOrder;

pub fn AtomicSwapper(comptime T: type) type {
    return struct {
        pool: MemoryPool(Ref),
        front: std.atomic.Value(*Ref),

        const Self = @This();

        const Ref = struct {
            data: T,
            refs: std.atomic.Value(usize),
        };

        pub fn init(allocator: Allocator, initial_front: T) !Self {
            var pool = try MemoryPool(Ref).initPreheated(allocator, 2);
            errdefer pool.deinit();

            const front = pool.create() catch unreachable;
            front.data = initial_front;
            front.refs = std.atomic.Value(usize).init(1);

            return .{
                .pool = pool,
                .front = std.atomic.Value(*Ref).init(front),
            };
        }

        pub fn deinit(self: *Self) void {
            self.pool.deinit();
        }

        pub fn acquireFront(self: *const Self) *const T {
            const ref = self.front.load(.Acquire);
            _ = ref.refs.fetchAdd(1, .Release);
            return &ref.data;
        }

        pub fn release(self: *Self, t: *const T) void {
            const ref: *Ref = @fieldParentPtr(Ref, "data", @constCast(t));
            if (ref.refs.fetchSub(1, .AcqRel) == 0) self.pool.destroy(ref);
        }

        pub fn createRef(self: *Self) !*Ref {
            const ref = try self.pool.create();
            ref.refs = std.atomic.Value(usize).init(1);
            return ref;
        }

        pub fn swapFront(self: *Self, ref: *Ref) void {
            const front = self.front.swap(ref, .Release);
            _ = front.refs.fetchSub(1, .Release);
        }
    };
}
