const std = @import("std");
const c = @import("c.zig");
const Sound = @import("assets").Sound;
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const log = std.log.scoped(.audio);

pub const AudioContext = struct {
    allocator: Allocator,
    sound_cache: Cache,

    buffer_buf: std.ArrayList(c.ALuint),

    sound_queue: Queue,
    sound_queue_free: Queue,
    sound_queue_nodes: [max_sources]Queue.Node,

    sources: SourceList,
    free_sources: SourceList,
    source_nodes: [max_sources]SourceList.Node,
    source_buf: [max_sources]c.ALuint,

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

    const max_sources = 64;
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
        errdefer _ = c.alcMakeContextCurrent(null);

        var source_buf: [max_sources]c.ALuint = undefined;
        c.alGenSources(@intCast(source_buf.len), &source_buf);
        try checkAlError();
        errdefer c.alDeleteSources(@intCast(source_buf.len), &source_buf);

        var self = try allocator.create(AudioContext);
        errdefer allocator.destroy(self);

        self.* = .{
            .allocator = allocator,
            .sound_cache = Cache.init(allocator),
            .sound_queue = .{},
            .sound_queue_free = .{},
            .sound_queue_nodes = undefined,
            .buffer_buf = std.ArrayList(c.ALuint).init(allocator),
            .sources = .{},
            .free_sources = .{},
            .source_nodes = undefined,
            .source_buf = source_buf,
            .thread = null,
            .stop_flag = std.atomic.Value(bool).init(false),
            .rwlock = .{},
            .dev = dev,
            .ctx = ctx,
            .avg_ticktime_s = std.atomic.Value(f64).init(@as(f64, poll_time) / std.time.ns_per_s),
            .gain = std.atomic.Value(f32).init(1),
        };

        for (&self.source_nodes, &source_buf) |*node, source| {
            node.data = source;
            self.free_sources.append(node);
        }

        for (&self.sound_queue_nodes) |*node| {
            self.sound_queue_free.append(node);
        }

        self.thread = try std.Thread.spawn(.{}, audioThread, .{self});
        return self;
    }

    pub fn deinit(self: *AudioContext) void {
        if (self.thread) |t| {
            self.stop_flag.store(true, .Release);
            t.join();
        }

        c.alSourceStopv(@intCast(self.source_buf.len), &self.source_buf);
        c.alDeleteSources(@intCast(self.source_buf.len), &self.source_buf);

        c.alDeleteBuffers(@intCast(self.buffer_buf.items.len), self.buffer_buf.items.ptr);
        self.buffer_buf.deinit();

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

            try self.buffer_buf.append(buffer);
            errdefer _ = self.buffer_buf.pop();

            try self.sound_cache.putNoClobber(sound.hash, .{ .sound = sound, .buffer = buffer });
        }
    }

    pub fn playSound(self: *AudioContext, hash: *const Sound.Hash) !void {
        const entry = blk: {
            self.rwlock.lockShared();
            defer self.rwlock.unlockShared();

            break :blk self.sound_cache.getPtr(hash.*) orelse return error.SoundNotCached;
        };

        self.rwlock.lock();
        defer self.rwlock.unlock();

        const node = self.sound_queue_free.pop() orelse (self.sound_queue.popFirst() orelse unreachable);
        node.data = entry.buffer;
        self.sound_queue.append(node);
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

        c.alListenerf(c.AL_GAIN, self.getGain());
        try checkAlError();

        self.removeFinishedSources();
        try self.startQueuedSounds();
    }

    fn removeFinishedSources(self: *AudioContext) void {
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
                self.destroySource(node);
            }
        }
    }

    fn startQueuedSounds(self: *AudioContext) !void {
        while (self.sound_queue.pop()) |node| {
            defer self.sound_queue_free.append(node);

            const buffer = node.data;
            const source_node = self.nextSource();
            errdefer self.destroySource(source_node);

            try playSource(source_node.data, buffer, 1);
        }
    }

    fn nextSource(self: *AudioContext) *SourceList.Node {
        if (self.free_sources.pop()) |node| {
            self.sources.append(node);
            return node;
        }
        // Recycle oldest source.
        const node = self.sources.first orelse unreachable;
        c.alSourceStop(node.data);
        checkAlError() catch |err| std.debug.panic("Failed to stop source 0x{}: {}", .{ node.data, err });
        return node;
    }

    fn destroySource(self: *AudioContext, node: *SourceList.Node) void {
        c.alSourceStop(node.data);
        checkAlError() catch |err| {
            log.warn("Failed to stop source {X}: {}", .{ node.data, err });
        };
        self.sources.remove(node);
        self.free_sources.append(node);
    }

    fn playSource(source: c.ALuint, buffer: c.ALuint, gain: f32) !void {
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
