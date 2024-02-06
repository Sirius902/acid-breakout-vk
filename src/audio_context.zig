const std = @import("std");
const c = @import("c.zig");
const Sound = @import("assets").Sound;
const Allocator = std.mem.Allocator;
const log = std.log.scoped(.audio);

pub const AudioContext = struct {
    allocator: Allocator,
    sound_cache: Cache,
    sound_queue: Queue,
    sources: SourceList,
    thread: ?std.Thread,
    stop_flag: std.atomic.Value(bool),
    rwlock: std.Thread.RwLock,
    dev: *c.ALCdevice,
    ctx: *c.ALCcontext,
    avg_ticktime_s: std.atomic.Value(f64),
    gain: std.atomic.Value(f32),

    const Cache = std.AutoHashMap(Sound.Hash, CacheEntry);

    const CacheEntry = struct {
        sound: *const Sound,
        buffer: c.ALuint,
    };

    const Queue = std.DoublyLinkedList(c.ALuint);
    const SourceList = std.DoublyLinkedList(c.ALuint);

    const poll_time = 16 * std.time.ns_per_ms;

    pub fn init(allocator: Allocator) !*AudioContext {
        // Use default audio device.
        const dev = c.alcOpenDevice(null) orelse return error.AlcOpenDevice;
        errdefer _ = c.alcCloseDevice(dev);

        const ctx_opt = c.alcCreateContext(dev, null);
        try checkAlcError(dev);
        const ctx = ctx_opt orelse return error.AlcCreateContext;
        errdefer _ = c.alcDestroyContext(ctx);

        if (c.alcMakeContextCurrent(ctx) == c.AL_FALSE) {
            try checkAlcError(dev);
            return error.AlcMakeContextCurrent;
        }

        // Disable spatial audio since we don't need it.
        c.alDistanceModel(c.AL_NONE);
        try checkAlError();

        var self = try allocator.create(AudioContext);
        errdefer allocator.destroy(self);

        self.* = .{
            .allocator = allocator,
            .sound_cache = Cache.init(allocator),
            .sound_queue = .{},
            .sources = .{},
            .thread = null,
            .stop_flag = std.atomic.Value(bool).init(false),
            .rwlock = .{},
            .dev = dev,
            .ctx = ctx,
            .avg_ticktime_s = std.atomic.Value(f64).init(@as(f64, poll_time) / std.time.ns_per_s),
            .gain = std.atomic.Value(f32).init(1),
        };
        errdefer self.deinit();

        self.thread = try std.Thread.spawn(.{}, audioThread, .{self});
        return self;
    }

    pub fn deinit(self: *AudioContext) void {
        if (self.thread) |t| {
            self.stop_flag.store(true, .Release);
            t.join();
        }

        while (self.sources.popFirst()) |node| {
            defer self.allocator.destroy(node);
            c.alDeleteSources(1, &node.data);
        }

        // Don't destroy buffers since they are cached.
        while (self.sound_queue.popFirst()) |node| self.allocator.destroy(node);

        var cache_iter = self.sound_cache.valueIterator();
        while (cache_iter.next()) |entry| c.alDeleteBuffers(1, &entry.buffer);
        self.sound_cache.deinit();

        _ = c.alcMakeContextCurrent(null);
        _ = c.alcDestroyContext(self.ctx);
        _ = c.alcCloseDevice(self.dev);

        self.allocator.destroy(self);
    }

    pub fn getGain(self: *const AudioContext) f32 {
        return self.gain.load(.Acquire);
    }

    pub fn isMuted(self: *const AudioContext) bool {
        return std.math.approxEqAbs(f32, self.getGain(), 0, std.math.floatEps(f32));
    }

    pub fn setGain(self: *AudioContext, gain: f32) void {
        self.gain.store(gain, .Release);
    }

    pub fn cacheSound(self: *AudioContext, sound: *const Sound) !void {
        {
            self.rwlock.lock();
            defer self.rwlock.unlock();

            if (self.sound_cache.contains(sound.hash)) return;
        }

        var buffer: c.ALuint = undefined;
        c.alGenBuffers(1, &buffer);
        try checkAlError();
        errdefer c.alDeleteBuffers(1, &buffer);

        const al_format: c.ALenum = switch (sound.format) {
            .mono8 => c.AL_FORMAT_MONO8,
            .mono16 => c.AL_FORMAT_MONO16,
            .stereo8 => c.AL_FORMAT_STEREO8,
            .stereo16 => c.AL_FORMAT_STEREO16,
        };

        c.alBufferData(buffer, al_format, sound.data.ptr, @intCast(sound.data.len), @intCast(sound.sample_rate));
        try checkAlError();

        {
            self.rwlock.lock();
            defer self.rwlock.unlock();

            try self.sound_cache.putNoClobber(sound.hash, .{ .sound = sound, .buffer = buffer });
        }
    }

    pub fn playSound(self: *AudioContext, hash: *const Sound.Hash) !void {
        const entry = blk: {
            self.rwlock.lockShared();
            defer self.rwlock.unlockShared();

            break :blk self.sound_cache.getPtr(hash.*) orelse return error.SoundNotCached;
        };
        const node = try self.allocator.create(Queue.Node);
        node.data = entry.buffer;

        self.rwlock.lock();
        defer self.rwlock.unlock();
        self.sound_queue.prepend(node);
    }

    pub fn averageTps(self: *const AudioContext) f64 {
        return 1.0 / self.avg_ticktime_s.load(.Acquire);
    }

    fn audioThread(self: *AudioContext) void {
        var tick_timer = std.time.Timer.start() catch @panic("Expected timer to be supported");
        while (!self.stop_flag.load(.Acquire)) {
            tick_timer.reset();
            self.tickAudio() catch |err| log.err("Audio thread error: {}", .{err});

            const tick_time = tick_timer.read();
            const sleep_time = poll_time - @min(tick_time, poll_time);
            // TODO: Windows will sleep for at least 30ms, see if more precision is required.
            if (sleep_time > 0) std.time.sleep(sleep_time);

            const alpha = 0.2;
            const ticktime_s = @as(f64, @floatFromInt(tick_timer.read())) / std.time.ns_per_s;
            self.avg_ticktime_s.store(alpha * ticktime_s + (1 - alpha) * self.avg_ticktime_s.load(.Unordered), .Release);
        }
    }

    fn tickAudio(self: *AudioContext) !void {
        self.rwlock.lock();
        defer self.rwlock.unlock();

        try self.removeFinishedSources();
        try self.startQueuedSounds();
    }

    fn startQueuedSounds(self: *AudioContext) !void {
        while (self.sound_queue.pop()) |node| {
            defer self.allocator.destroy(node);
            if (self.isMuted()) return;

            const buffer = node.data;
            const source_node = try self.allocator.create(SourceList.Node);
            errdefer self.allocator.destroy(source_node);

            source_node.data = try initSource(buffer, self.getGain());
            errdefer c.alDeleteSources(1, &source_node.data);

            self.sources.prepend(source_node);
        }
    }

    fn removeFinishedSources(self: *AudioContext) !void {
        const is_muted = self.isMuted();
        var state: c.ALint = c.AL_PLAYING;
        var source_node = self.sources.first;
        while (source_node) |node| {
            const next = node.next;
            defer source_node = next;

            var err_occured = false;
            c.alGetSourcei(node.data, c.AL_SOURCE_STATE, &state);
            checkAlError() catch |err| {
                log.err("Error checking source {} state: {}", .{ node.data, err });
                err_occured = true;
            };

            if (is_muted or state != c.AL_PLAYING or err_occured) {
                defer self.allocator.destroy(node);
                self.sources.remove(node);
                c.alDeleteSources(1, &node.data);
            }
        }
    }

    fn initSource(buffer: c.ALuint, gain: f32) !c.ALuint {
        var source: c.ALuint = undefined;
        c.alGenSources(1, &source);
        try checkAlError();
        errdefer c.alDeleteSources(1, &source);

        c.alSourcef(source, c.AL_PITCH, 1);
        try checkAlError();
        c.alSourcef(source, c.AL_GAIN, gain);
        try checkAlError();
        c.alSourcei(source, c.AL_LOOPING, c.AL_FALSE);
        try checkAlError();
        c.alSourcei(source, c.AL_BUFFER, @bitCast(buffer));
        try checkAlError();

        c.alSourcePlay(source);
        try checkAlError();

        return source;
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
