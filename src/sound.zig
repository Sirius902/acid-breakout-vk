const std = @import("std");
const c = @import("c.zig");
const zwav = @import("zwav");

pub const Sound = struct {
    format: c.ALenum,
    sample_rate: c.ALsizei,
    data: []const u8,
    hash: Hash,

    pub const Hash = [hash_size]u8;
    pub const hash_size = Hasher.digest_length;

    const Hasher = std.crypto.hash.sha2.Sha256;

    pub fn initWav(wav: *zwav.Wav) !Sound {
        const format = if (wav.header.num_channels == 1 and wav.header.bits_per_sample == 8)
            c.AL_FORMAT_MONO8
        else if (wav.header.num_channels == 1 and wav.header.bits_per_sample == 16)
            c.AL_FORMAT_MONO16
        else if (wav.header.num_channels == 2 and wav.header.bits_per_sample == 8)
            c.AL_FORMAT_STEREO8
        else if (wav.header.num_channels == 2 and wav.header.bits_per_sample == 16)
            c.AL_FORMAT_STEREO16
        else
            return error.UnsupportedWav;

        const sample_rate: c.ALsizei = @intCast(wav.header.sample_rate);

        var data: [wav.dataSize()]u8 = undefined;
        try wav.reader().readNoEof(&data);

        var hasher = Hasher.init(.{});
        hasher.update(std.mem.asBytes(&std.mem.nativeToLittle(c.ALenum, format)));
        hasher.update(std.mem.asBytes(&std.mem.nativeToLittle(c.ALsizei, sample_rate)));
        hasher.update(&data);

        return .{
            .format = format,
            .sample_rate = sample_rate,
            .data = &data,
            .hash = hasher.finalResult(),
        };
    }
};

/// Embeds a WAV sound file.
pub fn embedSound(comptime path: []const u8) Sound {
    comptime {
        @setEvalBranchQuota(100_000_000);

        const file: []const u8 = @embedFile(path);
        var wav = zwav.Wav.init(.{ .const_buffer = std.io.fixedBufferStream(file) }) catch @compileError("Expected valid sound file");
        return Sound.initWav(&wav) catch @compileError("Expected Sound.init to succeed");
    }
}
