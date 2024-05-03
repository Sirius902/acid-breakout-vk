const std = @import("std");
const zwav = @import("zwav");
const Sound = @import("Sound.zig");
const Allocator = std.mem.Allocator;

const Self = @This();

step: std.Build.Step,
generated_file: std.Build.GeneratedFile,
assets_dir_path: []const u8,
assets_dir: std.fs.Dir,
assets_file_out: std.ArrayList(u8),
assets: std.ArrayList(AssetInfo),

// Update when asset generation changes.
const salt = "xL8jGBNiue%^*(#(";

const Hasher = std.crypto.hash.blake2.Blake2b384;

pub const AssetInfo = struct {
    name: []const u8,
    path: []const u8,
    tag: AssetTag,
};

pub const AssetTag = enum {
    wav,
};

pub fn create(owner: *std.Build) *Self {
    const assets_dir_name = "assets";
    const self = owner.allocator.create(Self) catch @panic("OOM");
    self.* = .{
        .step = std.Build.Step.init(.{
            .id = .custom,
            .name = "assets",
            .owner = owner,
            .makeFn = make,
        }),
        .generated_file = undefined,
        .assets_dir_path = owner.cache_root.join(owner.allocator, &.{assets_dir_name}) catch @panic("OOM"),
        .assets_dir = owner.cache_root.handle.makeOpenPath(assets_dir_name, .{}) catch @panic("Failed to make assets directory"),
        .assets_file_out = std.ArrayList(u8).init(owner.allocator),
        .assets = std.ArrayList(AssetInfo).init(owner.allocator),
    };
    self.generated_file = .{ .step = &self.step };
    return self;
}

pub fn getModule(self: *const Self) *std.Build.Module {
    const asset_types = self.step.owner.createModule(.{ .root_source_file = .{ .path = "asset-gen/asset_types.zig" } });
    const module = self.step.owner.createModule(.{ .root_source_file = self.getSource() });
    module.addImport("asset_types", asset_types);
    return module;
}

pub fn getSource(self: *const Self) std.Build.LazyPath {
    return .{ .generated = &self.generated_file };
}

pub fn addAsset(self: *Self, info: AssetInfo) void {
    self.assets.append(info) catch @panic("OOM");
}

pub fn make(step: *std.Build.Step, progress: *std.Progress.Node) !void {
    _ = progress;
    const self: *Self = @fieldParentPtr("step", step);
    const b = self.step.owner;

    const AssetPaths = struct {
        in: []const u8,
        out: []const u8,
    };

    var asset_paths = std.ArrayList(AssetPaths).initCapacity(
        b.allocator,
        self.assets.items.len,
    ) catch @panic("OOM");

    var root_hasher = createHasher();
    for (self.assets.items) |info| {
        var asset_hasher = createHasher();

        const in_path = b.pathFromRoot(info.path);
        const stat = b.build_root.handle.statFile(info.path) catch |err| {
            std.log.err("Failed to stat asset {s} at \"{s}\": {}", .{ info.name, info.path, err });
            return err;
        };

        asset_hasher.update(in_path);
        asset_hasher.update(info.path);
        asset_hasher.update(std.mem.asBytes(&std.mem.nativeToLittle(i128, stat.ctime)));

        var asset_hash: [Hasher.digest_length]u8 = undefined;
        asset_hasher.final(&asset_hash);
        root_hasher.update(&asset_hash);

        const out_path = b.fmt("{s}.zig", .{std.fmt.fmtSliceHexLower(&asset_hash)});
        try asset_paths.append(.{ .in = in_path, .out = out_path });
    }

    var root_hash: [Hasher.digest_length]u8 = undefined;
    root_hasher.final(&root_hash);
    const root_path = b.pathJoin(&.{
        self.assets_dir_path,
        b.fmt("{s}.zig", .{std.fmt.fmtSliceHexLower(&root_hash)}),
    });

    self.generated_file.path = root_path;

    var is_root_cached = true;
    self.assets_dir.access(root_path, .{}) catch {
        is_root_cached = false;
    };
    if (is_root_cached) return;

    const root_out = self.assets_file_out.writer();
    try root_out.writeAll("pub usingnamespace @import(\"asset_types\");\n");

    for (self.assets.items, asset_paths.items) |info, paths| {
        var arena = std.heap.ArenaAllocator.init(b.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();

        try root_out.print("pub const {s} = @import(\"{s}\").asset;\n", .{ info.name, paths.out });

        var is_asset_cached = true;
        self.assets_dir.access(paths.out, .{}) catch {
            is_asset_cached = false;
        };
        if (is_asset_cached) continue;

        const asset_file_path = b.pathJoin(&.{ self.assets_dir_path, paths.out });
        switch (info.tag) {
            .wav => try generateWav(paths.in, asset_file_path, allocator),
        }
    }

    var root_file = try std.fs.createFileAbsolute(root_path, .{});
    defer root_file.close();
    try root_file.writeAll(self.assets_file_out.items);
}

fn createHasher() Hasher {
    var hasher = Hasher.init(.{});
    hasher.update(salt);
    return hasher;
}

fn generateWav(path: []const u8, out_path: []const u8, allocator: Allocator) !void {
    var in_file = try std.fs.openFileAbsolute(path, .{});
    defer in_file.close();

    var wav = try zwav.Wav.init(.{ .file = in_file });
    const sound = try Sound.initWav(&wav, allocator);

    var out_file = try std.fs.createFileAbsolute(out_path, .{});
    defer out_file.close();
    const out = out_file.writer();

    try out.writeAll("pub const asset = @import(\"asset_types\").Sound");
    try out.print("{{ .format = .{s}, .sample_rate = {}, .data = &[_]u8{any}, .hash = [_]u8{any} }};\n", .{ @tagName(sound.format), sound.sample_rate, sound.data, sound.hash });
}
