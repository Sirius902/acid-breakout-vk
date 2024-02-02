const std = @import("std");
const zwav = @import("zwav");
const Allocator = std.mem.Allocator;

const Self = @This();

format: Format,
sample_rate: u32,
data: []const u8,
hash: Hash,

pub const Format = enum {
    mono8,
    mono16,
    stereo8,
    stereo16,
};

pub const Hash = [hash_size]u8;
pub const hash_size = Hasher.digest_length;

const Hasher = std.crypto.hash.blake2.Blake2b384;

/// Caller must free `data`.
pub fn initWav(wav: *zwav.Wav, allocator: Allocator) !Self {
    const format: Format = if (wav.header.num_channels == 1 and wav.header.bits_per_sample == 8)
        .mono8
    else if (wav.header.num_channels == 1 and wav.header.bits_per_sample == 16)
        .mono16
    else if (wav.header.num_channels == 2 and wav.header.bits_per_sample == 8)
        .stereo8
    else if (wav.header.num_channels == 2 and wav.header.bits_per_sample == 16)
        .stereo16
    else
        return error.UnsupportedWav;

    const sample_rate = wav.header.sample_rate;
    const data = try wav.reader().readAllAlloc(allocator, std.math.maxInt(u64));

    var hasher = Hasher.init(.{});
    hasher.update(std.mem.asBytes(&std.mem.nativeToLittle(usize, @intFromEnum(format))));
    hasher.update(std.mem.asBytes(&std.mem.nativeToLittle(u32, sample_rate)));
    hasher.update(data);

    var self: Self = .{
        .format = format,
        .sample_rate = sample_rate,
        .data = data,
        .hash = undefined,
    };
    hasher.final(&self.hash);

    return self;
}
