const std = @import("std");
const builtin = @import("builtin");

pub const MaxAssets = 160;

pub const AssetKind = enum {
    terrain,
    building,
    doodad,
    water,
    unit,
    unknown,
};

pub const SpriteAsset = struct {
    id: u16,
    kind: AssetKind,
    path: []u8,
    name: []u8,
    width: f32 = 0,
    height: f32 = 0,
};

pub const AssetCatalog = struct {
    allocator: std.mem.Allocator,
    assets: std.ArrayList(SpriteAsset) = .empty,

    pub fn init(allocator: std.mem.Allocator) AssetCatalog {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *AssetCatalog) void {
        self.clear();
        self.assets.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn clear(self: *AssetCatalog) void {
        for (self.assets.items) |asset| {
            self.allocator.free(asset.path);
            self.allocator.free(asset.name);
        }
        self.assets.clearRetainingCapacity();
    }

    pub fn scan(self: *AssetCatalog, root_path: []const u8) !void {
        self.clear();
        if (comptime builtin.target.os.tag == .emscripten) {
            return self.scanManifest(root_path);
        }
        return self.scanDirectory(root_path);
    }

    fn scanDirectory(self: *AssetCatalog, root_path: []const u8) !void {
        var dir = if (std.fs.path.isAbsolute(root_path))
            try std.fs.openDirAbsolute(root_path, .{ .iterate = true })
        else
            try std.fs.cwd().openDir(root_path, .{ .iterate = true });
        defer dir.close();
        var walker = try dir.walk(self.allocator);
        defer walker.deinit();

        while (try walker.next()) |entry| {
            if (self.assets.items.len >= MaxAssets) break;
            if (entry.kind != .file or !endsWithIgnoreCase(entry.basename, ".png")) continue;
            try self.appendAsset(root_path, entry.path);
        }
        sortByPath(self.assets.items);
        for (self.assets.items, 0..) |*asset, i| asset.id = @intCast(i);
    }

    fn scanManifest(self: *AssetCatalog, root_path: []const u8) !void {
        var manifest_path_buf: [1024]u8 = undefined;
        const manifest_path = try std.fmt.bufPrint(&manifest_path_buf, "{s}/asset_manifest.txt", .{root_path});
        const bytes = try std.fs.cwd().readFileAlloc(self.allocator, manifest_path, 256 * 1024);
        defer self.allocator.free(bytes);

        var lines = std.mem.splitScalar(u8, bytes, '\n');
        while (lines.next()) |raw_line| {
            if (self.assets.items.len >= MaxAssets) break;
            const rel_path = std.mem.trim(u8, raw_line, " \t\r");
            if (rel_path.len == 0 or !endsWithIgnoreCase(rel_path, ".png")) continue;
            try self.appendAsset(root_path, rel_path);
        }
        sortByPath(self.assets.items);
        for (self.assets.items, 0..) |*asset, i| asset.id = @intCast(i);
    }

    fn appendAsset(self: *AssetCatalog, root_path: []const u8, rel_path: []const u8) !void {
        const full = try std.fs.path.join(self.allocator, &.{ root_path, rel_path });
        errdefer self.allocator.free(full);
        const base = std.fs.path.basename(rel_path);
        const name = try self.allocator.dupe(u8, base);
        errdefer self.allocator.free(name);
        try self.assets.append(self.allocator, .{
            .id = @intCast(self.assets.items.len),
            .kind = classifyPath(rel_path),
            .path = full,
            .name = name,
        });
    }

    pub fn firstOfKind(self: *const AssetCatalog, kind: AssetKind) ?u16 {
        for (self.assets.items) |asset| {
            if (asset.kind == kind) return asset.id;
        }
        return null;
    }

    pub fn nthOfKind(self: *const AssetCatalog, kind: AssetKind, n: usize) ?u16 {
        var seen: usize = 0;
        for (self.assets.items) |asset| {
            if (asset.kind != kind) continue;
            if (seen == n) return asset.id;
            seen += 1;
        }
        return null;
    }

    pub fn get(self: *const AssetCatalog, id: u16) ?*const SpriteAsset {
        if (id >= self.assets.items.len) return null;
        return &self.assets.items[id];
    }

    pub fn findByPathSuffix(self: *const AssetCatalog, suffix: []const u8) ?u16 {
        const normalized = trimLeadingSeparators(suffix);
        for (self.assets.items) |asset| {
            if (endsWithIgnoreCase(asset.path, normalized)) return asset.id;
        }
        return null;
    }
};

fn sortByPath(items: []SpriteAsset) void {
    std.mem.sort(SpriteAsset, items, {}, struct {
        fn lessThan(_: void, a: SpriteAsset, b: SpriteAsset) bool {
            const ar = kindRank(a.kind);
            const br = kindRank(b.kind);
            if (ar != br) return ar < br;
            return std.mem.lessThan(u8, a.path, b.path);
        }
    }.lessThan);
}

fn kindRank(kind: AssetKind) u8 {
    return switch (kind) {
        .terrain => 0,
        .water => 1,
        .building => 2,
        .doodad => 3,
        .unit => 4,
        .unknown => 5,
    };
}

fn classifyPath(path: []const u8) AssetKind {
    if (containsIgnoreCase(path, "citadel")) return .building;
    if (containsIgnoreCase(path, "imperator")) return .unit;
    if (containsIgnoreCase(path, "infantry")) return .unit;
    if (containsIgnoreCase(path, "captain")) return .unit;
    if (containsIgnoreCase(path, "artillery")) return .unit;
    if (containsIgnoreCase(path, "portal")) return .doodad;
    if (containsIgnoreCase(path, "healing")) return .doodad;
    if (containsIgnoreCase(path, "background")) return .terrain;
    if (containsIgnoreCase(path, "tileset")) return .terrain;
    if (containsIgnoreCase(path, "building")) return .building;
    if (containsIgnoreCase(path, "structures")) return .building;
    if (containsIgnoreCase(path, "water")) return .water;
    if (containsIgnoreCase(path, "unit")) return .unit;
    if (containsIgnoreCase(path, "doodads")) return .doodad;
    if (containsIgnoreCase(path, "rocks")) return .doodad;
    if (containsIgnoreCase(path, "flora")) return .doodad;
    return .unknown;
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0 or needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        var same = true;
        for (needle, 0..) |c, j| {
            if (std.ascii.toLower(haystack[i + j]) != std.ascii.toLower(c)) {
                same = false;
                break;
            }
        }
        if (same) return true;
    }
    return false;
}

fn endsWithIgnoreCase(haystack: []const u8, suffix: []const u8) bool {
    if (suffix.len > haystack.len) return false;
    return containsIgnoreCase(haystack[haystack.len - suffix.len ..], suffix);
}

fn trimLeadingSeparators(path: []const u8) []const u8 {
    var start: usize = 0;
    while (start < path.len and (path[start] == '/' or path[start] == '\\')) : (start += 1) {}
    return path[start..];
}
