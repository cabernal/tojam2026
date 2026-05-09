const std = @import("std");
const builtin = @import("builtin");

pub const MaxAssets = 96;

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
        for (self.assets.items) |asset| {
            self.allocator.free(asset.path);
            self.allocator.free(asset.name);
        }
        self.assets.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn scan(self: *AssetCatalog, root_path: []const u8) !void {
        if (builtin.target.os.tag == .emscripten) {
            return self.scanStaticWeb(root_path);
        }
        var dir = try std.fs.cwd().openDir(root_path, .{ .iterate = true });
        defer dir.close();
        var walker = try dir.walk(self.allocator);
        defer walker.deinit();

        while (try walker.next()) |entry| {
            if (self.assets.items.len >= MaxAssets) break;
            if (entry.kind != .file or !endsWithIgnoreCase(entry.basename, ".png")) continue;
            const rel = try std.fs.path.join(self.allocator, &.{ root_path, entry.path });
            errdefer self.allocator.free(rel);
            const name = try self.allocator.dupe(u8, entry.basename);
            errdefer self.allocator.free(name);
            try self.assets.append(self.allocator, .{
                .id = @intCast(self.assets.items.len),
                .kind = classifyPath(entry.path),
                .path = rel,
                .name = name,
            });
        }
        sortByPath(self.assets.items);
        for (self.assets.items, 0..) |*asset, i| asset.id = @intCast(i);
    }

    fn scanStaticWeb(self: *AssetCatalog, root_path: []const u8) !void {
        for (WebAssetPaths) |rel_path| {
            if (self.assets.items.len >= MaxAssets) break;
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
        sortByPath(self.assets.items);
        for (self.assets.items, 0..) |*asset, i| asset.id = @intCast(i);
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
};

const WebAssetPaths = [_][]const u8{
    "tilesets/arid_badlands/backgrounds/Desert_BG_2 - dark.png",
    "tilesets/arid_badlands/backgrounds/Desert_BG_2 - light.png",
    "tilesets/arid_badlands/backgrounds/Desert_BG_2 - medium.png",
    "tilesets/arid_badlands/backgrounds/Desert_BG_2 - pale.png",
    "doodads/arid_badlands/flora/Acacia Style Trees Patch 2z2 B-green.png",
    "doodads/arid_badlands/flora/Giant Cactus Patch 2x2 A-green.png",
    "doodads/arid_badlands/odds/Rail Segment 2.2.png",
    "doodads/arid_badlands/rocks/Dersert Rocks - Size 1A - light.png",
    "doodads/arid_badlands/rocks/Dersert Rocks - Size 1B - medium.png",
    "doodads/arid_badlands/rocks/Dersert Rocks - Size 2A - dark.png",
    "doodads/arid_badlands/rocks/Desert Small Rockpile- Dif terrain C - light.png",
    "doodads/arid_badlands/waterways/Sandy Waterway 1 - Open Water.png",
    "doodads/arid_badlands/waterways/Sandy Waterway 1 - corner north.png",
    "doodads/arid_badlands/waterways/Sandy Waterway 1 - long straight1.png",
    "buildings/arid_badlands/Building A1.1 sz2 shadow.png",
    "buildings/arid_badlands/Building B sz2 noshadow.png",
    "buildings/arid_badlands/Building C sz1 noshadow.png",
    "buildings/arid_badlands/Building H1.2 sz1 shadow.png",
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
