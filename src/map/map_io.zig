const std = @import("std");
const schema = @import("schema.zig");
const map_mod = @import("map.zig");

pub const SaveError = error{
    InvalidMap,
} || std.fs.File.OpenError || std.fs.File.WriteError || std.fs.Dir.MakeError;

pub fn save(path: []const u8, map: *const map_mod.GameMap) !void {
    try makeParentPath(path);
    var file = if (std.fs.path.isAbsolute(path))
        try std.fs.createFileAbsolute(path, .{ .truncate = true })
    else
        try std.fs.cwd().createFile(path, .{ .truncate = true });
    defer file.close();
    var buffer: [8192]u8 = undefined;
    var writer = file.writer(&buffer);
    const w = &writer.interface;

    try w.print(
        "{{\n  \"schema_version\": {d},\n  \"width\": {d},\n  \"height\": {d},\n  \"terrain\": [\n",
        .{ schema.SchemaVersion, map.width, map.height },
    );

    for (0..map.height) |y| {
        try w.writeAll("    [");
        for (0..map.width) |x| {
            const cell = map.terrain[y][x];
            if (x != 0) try w.writeAll(", ");
            try w.print(
                "{{\"terrain_id\":{d},\"asset_id\":{d},\"walkable\":{},\"buildable\":{},\"movement_cost\":{d},\"height\":{d}}}",
                .{ cell.terrain_id, cell.asset_id, cell.walkable, cell.buildable, cell.movement_cost, cell.height },
            );
        }
        try w.writeAll(if (y + 1 == map.height) "]\n" else "],\n");
    }

    try w.writeAll("  ],\n  \"objects\": [\n");
    for (map.objects[0..map.object_count], 0..) |object, i| {
        try w.print(
            "    {{\"id\":{d},\"kind\":\"{s}\",\"x\":{d},\"y\":{d},\"owner\":{d},\"team\":{d},\"hp\":{d:.2},\"max_hp\":{d:.2},\"facing\":[{d},{d}],\"asset_id\":{d},\"active\":{}}}",
            .{
                object.id,
                object.kind.jsonName(),
                object.x,
                object.y,
                object.owner,
                object.team,
                object.hp,
                object.max_hp,
                object.facing_x,
                object.facing_y,
                object.asset_id,
                object.active,
            },
        );
        try w.writeAll(if (i + 1 == map.object_count) "\n" else ",\n");
    }
    try w.print("  ],\n  \"next_object_id\": {d}\n}}\n", .{map.next_object_id});
    try w.flush();
}

pub fn load(allocator: std.mem.Allocator, path: []const u8) !map_mod.GameMap {
    const bytes = try readFileAllocPath(allocator, path, 16 * 1024 * 1024);
    defer allocator.free(bytes);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
    defer parsed.deinit();

    const root = parsed.value.object;
    const schema_version = intField(root, "schema_version", 0);
    if (schema_version != schema.SchemaVersion) return error.UnsupportedSchemaVersion;
    const width = intField(root, "width", 0);
    const height = intField(root, "height", 0);
    if (width != schema.MapW or height != schema.MapH) return error.InvalidMapDimensions;

    var map: map_mod.GameMap = .{};
    map.width = schema.MapW;
    map.height = schema.MapH;

    const terrain_rows = root.get("terrain") orelse return error.MissingTerrain;
    for (terrain_rows.array.items, 0..) |row_value, y| {
        if (y >= schema.MapH) break;
        for (row_value.array.items, 0..) |cell_value, x| {
            if (x >= schema.MapW) break;
            const cell_obj = cell_value.object;
            map.terrain[y][x] = .{
                .terrain_id = @intCast(intField(cell_obj, "terrain_id", 0)),
                .asset_id = @intCast(intField(cell_obj, "asset_id", 0)),
                .walkable = boolField(cell_obj, "walkable", true),
                .buildable = boolField(cell_obj, "buildable", true),
                .movement_cost = @intCast(@max(1, intField(cell_obj, "movement_cost", 1))),
                .height = @intCast(intField(cell_obj, "height", 0)),
            };
        }
    }

    const objects = root.get("objects") orelse return error.MissingObjects;
    for (objects.array.items) |object_value| {
        if (map.object_count >= schema.MaxObjects) break;
        const object_obj = object_value.object;
        const kind_name = object_obj.get("kind") orelse return error.InvalidObject;
        const kind = schema.ObjectKind.fromJsonName(kind_name.string) orelse return error.InvalidObject;
        var object: map_mod.MapObject = .{
            .id = @intCast(intField(object_obj, "id", 0)),
            .kind = kind,
            .x = @intCast(intField(object_obj, "x", 0)),
            .y = @intCast(intField(object_obj, "y", 0)),
            .owner = @intCast(intField(object_obj, "owner", 0)),
            .team = @intCast(intField(object_obj, "team", 0)),
            .hp = floatField(object_obj, "hp", map_mod.defaultStats(kind).hp),
            .max_hp = floatField(object_obj, "max_hp", map_mod.defaultStats(kind).hp),
            .asset_id = @intCast(intField(object_obj, "asset_id", 0)),
            .active = boolField(object_obj, "active", true),
        };
        if (object_obj.get("facing")) |facing| {
            if (facing.array.items.len >= 2) {
                object.facing_x = @intCast(valueInt(facing.array.items[0], 1));
                object.facing_y = @intCast(valueInt(facing.array.items[1], 0));
            }
        }
        map.objects[map.object_count] = object;
        map.object_count += 1;
        map.next_object_id = @max(map.next_object_id, object.id + 1);
    }
    map.next_object_id = @intCast(@max(@as(i64, map.next_object_id), intField(root, "next_object_id", map.next_object_id)));
    map.version += 1;
    return map;
}

fn makeParentPath(path: []const u8) !void {
    const dir_path = std.fs.path.dirname(path) orelse return;
    if (std.fs.path.isAbsolute(dir_path)) {
        std.fs.makeDirAbsolute(dir_path) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
    } else {
        try std.fs.cwd().makePath(dir_path);
    }
}

fn readFileAllocPath(allocator: std.mem.Allocator, path: []const u8, max_bytes: usize) ![]u8 {
    if (std.fs.path.isAbsolute(path)) {
        var file = try std.fs.openFileAbsolute(path, .{});
        defer file.close();
        return try file.readToEndAlloc(allocator, max_bytes);
    }
    return try std.fs.cwd().readFileAlloc(allocator, path, max_bytes);
}

fn intField(obj: std.json.ObjectMap, key: []const u8, default: i64) i64 {
    const value = obj.get(key) orelse return default;
    return @intCast(valueInt(value, default));
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

test "map serialization is deterministic and loadable" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const rel = "map.json";
    var map = map_mod.GameMap.initDefault();
    try saveToDir(tmp.dir, rel, &map);
    const first = try tmp.dir.readFileAlloc(std.testing.allocator, rel, 1024 * 1024);
    defer std.testing.allocator.free(first);
    try saveToDir(tmp.dir, rel, &map);
    const second = try tmp.dir.readFileAlloc(std.testing.allocator, rel, 1024 * 1024);
    defer std.testing.allocator.free(second);
    try std.testing.expectEqualStrings(first, second);

    const loaded = try loadFromDir(std.testing.allocator, tmp.dir, rel);
    try std.testing.expectEqual(map.object_count, loaded.object_count);
    try std.testing.expectEqual(map.terrain[0][0].terrain_id, loaded.terrain[0][0].terrain_id);
}

fn saveToDir(dir: std.fs.Dir, path: []const u8, map: *const map_mod.GameMap) !void {
    var file = try dir.createFile(path, .{ .truncate = true });
    defer file.close();
    var buffer: [8192]u8 = undefined;
    var writer = file.writer(&buffer);
    const w = &writer.interface;
    try w.print("{{\"schema_version\":{d},\"width\":{d},\"height\":{d},\"terrain\":[", .{ schema.SchemaVersion, map.width, map.height });
    for (0..map.height) |y| {
        if (y != 0) try w.writeAll(",");
        try w.writeAll("[");
        for (0..map.width) |x| {
            if (x != 0) try w.writeAll(",");
            const cell = map.terrain[y][x];
            try w.print("{{\"terrain_id\":{d},\"asset_id\":{d},\"walkable\":{},\"buildable\":{},\"movement_cost\":{d},\"height\":{d}}}", .{ cell.terrain_id, cell.asset_id, cell.walkable, cell.buildable, cell.movement_cost, cell.height });
        }
        try w.writeAll("]");
    }
    try w.writeAll("],\"objects\":[");
    for (map.objects[0..map.object_count], 0..) |object, i| {
        if (i != 0) try w.writeAll(",");
        try w.print("{{\"id\":{d},\"kind\":\"{s}\",\"x\":{d},\"y\":{d},\"owner\":{d},\"team\":{d},\"hp\":{d:.2},\"max_hp\":{d:.2},\"facing\":[{d},{d}],\"asset_id\":{d},\"active\":{}}}", .{ object.id, object.kind.jsonName(), object.x, object.y, object.owner, object.team, object.hp, object.max_hp, object.facing_x, object.facing_y, object.asset_id, object.active });
    }
    try w.print("],\"next_object_id\":{d}}}", .{map.next_object_id});
    try w.flush();
}

fn loadFromDir(allocator: std.mem.Allocator, dir: std.fs.Dir, path: []const u8) !map_mod.GameMap {
    const bytes = try dir.readFileAlloc(allocator, path, 1024 * 1024);
    defer allocator.free(bytes);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    if (intField(root, "schema_version", 0) != schema.SchemaVersion) return error.UnsupportedSchemaVersion;
    var result: map_mod.GameMap = .{};
    const terrain_rows = root.get("terrain").?.array.items;
    for (terrain_rows, 0..) |row, y| {
        for (row.array.items, 0..) |cell_value, x| {
            const cell_obj = cell_value.object;
            result.terrain[y][x] = .{
                .terrain_id = @intCast(intField(cell_obj, "terrain_id", 0)),
                .asset_id = @intCast(intField(cell_obj, "asset_id", 0)),
                .walkable = boolField(cell_obj, "walkable", true),
                .buildable = boolField(cell_obj, "buildable", true),
                .movement_cost = @intCast(intField(cell_obj, "movement_cost", 1)),
                .height = @intCast(intField(cell_obj, "height", 0)),
            };
        }
    }
    for (root.get("objects").?.array.items) |object_value| {
        const object_obj = object_value.object;
        const kind = schema.ObjectKind.fromJsonName(object_obj.get("kind").?.string).?;
        result.objects[result.object_count] = .{
            .id = @intCast(intField(object_obj, "id", 0)),
            .kind = kind,
            .x = @intCast(intField(object_obj, "x", 0)),
            .y = @intCast(intField(object_obj, "y", 0)),
            .owner = @intCast(intField(object_obj, "owner", 0)),
            .team = @intCast(intField(object_obj, "team", 0)),
            .hp = floatField(object_obj, "hp", 0),
            .max_hp = floatField(object_obj, "max_hp", 0),
            .asset_id = @intCast(intField(object_obj, "asset_id", 0)),
            .active = boolField(object_obj, "active", true),
        };
        result.object_count += 1;
    }
    return result;
}
