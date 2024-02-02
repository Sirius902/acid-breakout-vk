pub const Game = struct {
    pub fn init() !Game {
        return .{};
    }

    pub fn deinit(self: *Game) void {
        _ = self;
    }
};
