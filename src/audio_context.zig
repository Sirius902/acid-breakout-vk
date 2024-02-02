const std = @import("std");
const c = @import("c.zig");
const zwav = @import("zwav");
const Sound = @import("sound.zig").Sound;
const Allocator = std.mem.Allocator;
const log = std.log.scoped(.audio);

pub const AudioContext = struct {
    allocator: Allocator,
    sound_cache: Cache,
    sound_queue: Queue,
    sources: SourceList,
    thread: ?std.Thread,
    stop_flag: AtomicBool,
    rwlock: std.Thread.RwLock,
    dev: *c.ALCdevice,
    ctx: *c.ALCcontext,

    const AtomicBool = std.atomic.Value(bool);

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

        var self = try allocator.create(AudioContext);
        errdefer allocator.destroy(self);

        self.* = .{
            .allocator = allocator,
            .sound_cache = Cache.init(allocator),
            .sound_queue = .{},
            .sources = .{},
            .thread = null,
            .stop_flag = AtomicBool.init(false),
            .rwlock = .{},
            .dev = dev,
            .ctx = ctx,
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

        _ = c.alcDestroyContext(self.ctx);
        _ = c.alcCloseDevice(self.dev);

        self.allocator.destroy(self);
    }

    pub fn cacheSound(self: *AudioContext, sound: *const Sound) !void {
        self.rwlock.lock();
        defer self.rwlock.unlock();

        if (self.sound_cache.contains(sound.hash)) return;

        var buffer: c.ALuint = undefined;
        c.alGenBuffers(1, &buffer);
        try checkAlError();
        errdefer c.alDeleteBuffers(1, &buffer);

        c.alBufferData(buffer, sound.format, sound.data.ptr, @intCast(sound.data.len), sound.sample_rate);
        try checkAlError();

        try self.sound_cache.putNoClobber(sound.hash, .{ .sound = sound, .buffer = buffer });
    }

    pub fn playSound(self: *AudioContext, hash: *const Sound.Hash) !void {
        self.rwlock.lockShared();
        defer self.rwlock.unlockShared();

        const entry = self.sound_cache.getPtr(hash.*) orelse return error.SoundNotCached;
        const node = try self.allocator.create(Queue.Node);
        node.data = entry.buffer;
        self.sound_queue.prepend(node);
    }

    fn audioThread(self: *AudioContext) void {
        var tick_start = std.time.nanoTimestamp();
        while (!self.stop_flag.load(.Acquire)) {
            const tick_end = std.time.nanoTimestamp();
            defer {
                const tick_time: u64 = @intCast(tick_end - tick_start);
                const sleep_time = poll_time - @min(tick_time, poll_time);
                // TODO: Windows will sleep for at least 30ms, see if more precision is required.
                if (sleep_time > 0) std.time.sleep(sleep_time);
                tick_start = std.time.nanoTimestamp();
            }

            self.tickAudio() catch |err| log.err("Audio thread error: {}", .{err});
        }
    }

    fn tickAudio(self: *AudioContext) !void {
        self.rwlock.lock();
        defer self.rwlock.unlock();

        try self.startQueuedSounds();
        try self.removeFinishedSources();
    }

    fn startQueuedSounds(self: *AudioContext) !void {
        while (self.sound_queue.pop()) |node| {
            defer self.allocator.destroy(node);
            const buffer = node.data;

            const source_node = try self.allocator.create(SourceList.Node);
            errdefer self.allocator.destroy(source_node);

            source_node.data = try initSource(buffer);
            errdefer c.alDeleteSources(1, &source_node.data);

            self.sources.prepend(source_node);
        }
    }

    fn removeFinishedSources(self: *AudioContext) !void {
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

            if (state != c.AL_PLAYING or err_occured) {
                defer self.allocator.destroy(node);
                self.sources.remove(node);
                c.alDeleteSources(1, &node.data);
            }
        }
    }

    fn initSource(buffer: c.ALuint) !c.ALuint {
        var source: c.ALuint = undefined;
        c.alGenSources(1, &source);
        try checkAlError();
        errdefer c.alDeleteSources(1, &source);

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
