const std = @import("std");
const c = @import("c.zig");
const log = std.log.scoped(.audio);

pub const AudioContext = struct {
    dev: *c.ALCdevice,
    ctx: *c.ALCcontext,

    pub fn init() !AudioContext {
        // Use default audio device
        const dev = c.alcOpenDevice(null) orelse return error.AlcOpenDevice;
        errdefer _ = c.alcCloseDevice(dev);

        // TODO: See if ALC_SYNC should be specified
        const ctx_opt = c.alcCreateContext(dev, null);
        try checkAlcError(dev);
        const ctx = ctx_opt orelse return error.AlcCreateContext;
        errdefer _ = c.alcDestroyContext(ctx);

        if (c.alcMakeContextCurrent(ctx) == c.AL_FALSE) {
            try checkAlcError(dev);
            return error.AlcMakeContextCurrent;
        }

        return .{ .dev = dev, .ctx = ctx };
    }

    pub fn deinit(self: AudioContext) void {
        _ = c.alcDestroyContext(self.ctx);
        _ = c.alcCloseDevice(self.dev);
    }

    pub fn playTestSound(self: AudioContext) !void {
        _ = self;
        const test_sample: []const u8 = @embedFile("assets/test.raw");

        var buffer: c.ALuint = undefined;
        c.alGenBuffers(1, &buffer);
        try checkAlError();
        defer c.alDeleteBuffers(1, &buffer);

        c.alBufferData(buffer, c.AL_FORMAT_STEREO16, test_sample.ptr, test_sample.len, 48000);
        try checkAlError();

        var source: c.ALuint = undefined;
        c.alGenSources(1, &source);
        try checkAlError();
        defer c.alDeleteSources(1, &source);

        c.alSourcef(source, c.AL_PITCH, 1);
        try checkAlError();
        c.alSourcef(source, c.AL_GAIN, 1);
        try checkAlError();
        c.alSource3f(source, c.AL_POSITION, 0, 0, 0);
        try checkAlError();
        c.alSource3f(source, c.AL_VELOCITY, 0, 0, 0);
        try checkAlError();
        c.alSourcei(source, c.AL_LOOPING, c.AL_FALSE);
        try checkAlError();
        c.alSourcei(source, c.AL_BUFFER, @bitCast(buffer));
        try checkAlError();

        c.alSourcePlay(source);
        try checkAlError();

        var state = c.AL_PLAYING;
        while (state == c.AL_PLAYING) {
            c.alGetSourcei(source, c.AL_SOURCE_STATE, &state);
            try checkAlError();
        }
    }
};

pub const AudioError = error{
    InvalidName,
    InvalidEnum,
    InvalidValue,
    InvalidOperation,
    OutOfMemory,
};

pub const ContextError = error{
    InvalidValue,
    InvalidDevice,
    InvalidContext,
    InvalidEnum,
    OutOfMemory,
};

fn checkAlError() AudioError!void {
    return switch (c.alGetError()) {
        c.AL_NO_ERROR => {},
        c.AL_INVALID_NAME => error.InvalidName,
        c.AL_INVALID_ENUM => error.InvalidEnum,
        c.AL_INVALID_VALUE => error.InvalidValue,
        c.AL_INVALID_OPERATION => error.InvalidOperation,
        c.AL_OUT_OF_MEMORY => error.OutOfMemory,
        else => |err| std.debug.panic("Unexpected OpenAL error: {}\n", .{err}),
    };
}

fn checkAlcError(dev: *c.ALCdevice) ContextError!void {
    return switch (c.alcGetError(dev)) {
        c.ALC_NO_ERROR => {},
        c.ALC_INVALID_VALUE => error.InvalidValue,
        c.ALC_INVALID_DEVICE => error.InvalidDevice,
        c.ALC_INVALID_CONTEXT => error.InvalidContext,
        c.ALC_INVALID_ENUM => error.InvalidEnum,
        c.ALC_OUT_OF_MEMORY => error.OutOfMemory,
        else => |err| std.debug.panic("Unexpected OpenAL context error: {}\n", .{err}),
    };
}
