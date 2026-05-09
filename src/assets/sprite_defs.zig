const std = @import("std");
const schema = @import("../map/schema.zig");
const asset_loader = @import("asset_loader.zig");

pub const MaxObjectSpriteDefs = 64;

pub const ObjectSpriteDef = struct {
    kind: schema.ObjectKind,
    asset_path: []u8,
    asset_id: ?u16 = null,
    draw_width: f32 = 64,
    draw_height: f32 = 64,
    anchor_x: f32 = 0.5,
    anchor_y: f32 = 1.0,
    offset_x: f32 = 0,
    offset_y: f32 = 0,
    footprint_w: u8 = 1,
    footprint_h: u8 = 1,
    team_badge: bool = false,
};

pub const SpriteDefinitions = struct {
    allocator: std.mem.Allocator,
    objects: std.ArrayList(ObjectSpriteDef) = .empty,

    pub fn init(allocator: std.mem.Allocator) SpriteDefinitions {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *SpriteDefinitions) void {
        self.clear();
        self.objects.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn clear(self: *SpriteDefinitions) void {
        for (self.objects.items) |def| {
            self.allocator.free(def.asset_path);
        }
        self.objects.clearRetainingCapacity();
    }

    pub fn loadFromFile(self: *SpriteDefinitions, path: []const u8, catalog: *const asset_loader.AssetCatalog) !void {
        const bytes = try std.fs.cwd().readFileAlloc(self.allocator, path, 256 * 1024);
        defer self.allocator.free(bytes);
        try self.loadFromSlice(bytes, catalog);
    }

    pub fn loadFromSlice(self: *SpriteDefinitions, bytes: []const u8, catalog: *const asset_loader.AssetCatalog) !void {
        self.clear();
        var parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, bytes, .{});
        defer parsed.deinit();

        const root = switch (parsed.value) {
            .object => |object| object,
            else => return error.InvalidSpriteDefinitions,
        };
        const objects_value = root.get("objects") orelse return error.MissingObjectSprites;
        const object_items = switch (objects_value) {
            .array => |array| array.items,
            else => return error.InvalidSpriteDefinitions,
        };

        for (object_items) |entry_value| {
            if (self.objects.items.len >= MaxObjectSpriteDefs) break;
            const entry = switch (entry_value) {
                .object => |object| object,
                else => return error.InvalidObjectSprite,
            };
            const kind_name = stringField(entry, "kind") orelse return error.InvalidObjectSprite;
            const kind = schema.ObjectKind.fromJsonName(kind_name) orelse return error.InvalidObjectSprite;
            const asset_path = stringField(entry, "asset") orelse return error.InvalidObjectSprite;
            const path_copy = try self.allocator.dupe(u8, asset_path);
            errdefer self.allocator.free(path_copy);

            var def: ObjectSpriteDef = .{
                .kind = kind,
                .asset_path = path_copy,
                .asset_id = catalog.findByPathSuffix(asset_path),
                .draw_width = floatField(entry, "draw_width", 64),
                .draw_height = floatField(entry, "draw_height", 64),
                .anchor_x = floatField(entry, "anchor_x", 0.5),
                .anchor_y = floatField(entry, "anchor_y", 1.0),
                .offset_x = floatField(entry, "offset_x", 0),
                .offset_y = floatField(entry, "offset_y", 0),
                .team_badge = boolField(entry, "team_badge", false),
            };
            readFootprint(entry, &def);
            try self.objects.append(self.allocator, def);
        }
    }

    pub fn get(self: *const SpriteDefinitions, kind: schema.ObjectKind) ?*const ObjectSpriteDef {
        for (self.objects.items) |*def| {
            if (def.kind == kind) return def;
        }
        return null;
    }

    pub fn assetForKind(self: *const SpriteDefinitions, kind: schema.ObjectKind) ?u16 {
        const def = self.get(kind) orelse return null;
        return def.asset_id;
    }
};

fn readFootprint(obj: std.json.ObjectMap, def: *ObjectSpriteDef) void {
    const value = obj.get("footprint") orelse return;
    switch (value) {
        .array => |array| {
            if (array.items.len >= 1) def.footprint_w = clampedU8(valueInt(array.items[0], 1), 1, 8);
            if (array.items.len >= 2) def.footprint_h = clampedU8(valueInt(array.items[1], 1), 1, 8);
        },
        else => {},
    }
}

fn stringField(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = obj.get(key) orelse return null;
    return switch (value) {
        .string => |string| string,
        else => null,
    };
}

fn boolField(obj: std.json.ObjectMap, key: []const u8, default: bool) bool {
    const value = obj.get(key) orelse return default;
    return switch (value) {
        .bool => |b| b,
        else => default,
    };
}

fn floatField(obj: std.json.ObjectMap, key: []const u8, default: f32) f32 {
    const value = obj.get(key) orelse return default;
    return switch (value) {
        .float => |f| @floatCast(f),
        .integer => |i| @floatFromInt(i),
        else => default,
    };
}

fn valueInt(value: std.json.Value, default: i64) i64 {
    return switch (value) {
        .integer => |i| @intCast(i),
        .float => |f| @intFromFloat(f),
        else => default,
    };
}

fn clampedU8(value: i64, min: u8, max: u8) u8 {
    return @intCast(std.math.clamp(value, min, max));
}

test "sprite definitions resolve catalog asset ids" {
    var catalog = asset_loader.AssetCatalog.init(std.testing.allocator);
    defer catalog.deinit();

    const path = try std.testing.allocator.dupe(u8, "assets/sprites/starter/infantry.png");
    errdefer std.testing.allocator.free(path);
    const name = try std.testing.allocator.dupe(u8, "infantry.png");
    errdefer std.testing.allocator.free(name);
    try catalog.assets.append(std.testing.allocator, .{
        .id = 0,
        .kind = .unit,
        .path = path,
        .name = name,
    });

    var defs = SpriteDefinitions.init(std.testing.allocator);
    defer defs.deinit();
    try defs.loadFromSlice(
        \\{"schema_version":1,"objects":[{"kind":"infantry","asset":"sprites/starter/infantry.png","draw_width":48,"footprint":[1,1],"team_badge":true}]}
    , &catalog);

    const def = defs.get(.infantry).?;
    try std.testing.expectEqual(@as(?u16, 0), def.asset_id);
    try std.testing.expectEqual(@as(f32, 48), def.draw_width);
    try std.testing.expect(def.team_badge);
}
