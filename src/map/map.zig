const std = @import("std");
const schema = @import("schema.zig");
const path_grid = @import("../pathfinding/grid_map.zig");

pub const MapW = schema.MapW;
pub const MapH = schema.MapH;
pub const MaxObjects = schema.MaxObjects;
pub const ObjectKind = schema.ObjectKind;

pub const TerrainCell = struct {
    terrain_id: u8 = 0,
    asset_id: u16 = 0,
    walkable: bool = true,
    buildable: bool = true,
    movement_cost: u16 = 1,
    height: i16 = 0,
};

pub const MapObject = struct {
    id: u32 = 0,
    kind: ObjectKind = .infantry,
    x: i32 = 0,
    y: i32 = 0,
    owner: u8 = 0,
    team: u8 = 0,
    hp: f32 = 100,
    max_hp: f32 = 100,
    facing_x: i8 = 1,
    facing_y: i8 = 0,
    asset_id: u16 = 0,
    active: bool = true,
};

pub const GameMap = struct {
    width: usize = MapW,
    height: usize = MapH,
    terrain: [MapH][MapW]TerrainCell = [_][MapW]TerrainCell{[_]TerrainCell{.{}} ** MapW} ** MapH,
    objects: [MaxObjects]MapObject = [_]MapObject{.{}} ** MaxObjects,
    object_count: usize = 0,
    next_object_id: u32 = 1,
    version: u64 = 1,

    pub fn initDefault() GameMap {
        var map: GameMap = .{};
        map.paintStarterTerrain();
        _ = map.addObject(.citadel, 3, 15, 0, 0, 0);
        _ = map.addObject(.imperator, 5, 15, 0, 0, 0);
        _ = map.addObject(.citadel, 28, 15, 1, 1, 1);
        _ = map.addObject(.imperator, 26, 15, 1, 1, 1);
        _ = map.addObject(.portal, 12, 10, 0, 0, 3);
        _ = map.addObject(.portal, 20, 21, 1, 1, 3);
        _ = map.addObject(.healing_pod, 8, 24, 0, 0, 2);
        _ = map.addObject(.healing_pod, 23, 7, 1, 1, 2);
        _ = map.addObject(.outpost, 4, 12, 0, 0, 0);
        _ = map.addObject(.defense_grid, 4, 18, 0, 0, 0);
        _ = map.addObject(.outpost, 27, 18, 1, 1, 0);
        _ = map.addObject(.defense_grid, 27, 12, 1, 1, 0);
        _ = map.addObject(.obstacle, 2, 8, 0, 0, 0);
        _ = map.addObject(.obstacle, 7, 6, 0, 0, 0);
        _ = map.addObject(.obstacle, 11, 25, 0, 0, 0);
        _ = map.addObject(.obstacle, 20, 6, 1, 1, 0);
        _ = map.addObject(.obstacle, 24, 25, 1, 1, 0);
        _ = map.addObject(.obstacle, 30, 21, 1, 1, 0);
        for (0..9) |i| {
            _ = map.addObject(.infantry, 6, 10 + @as(i32, @intCast(i)), 0, 0, 0);
            _ = map.addObject(.infantry, 25, 10 + @as(i32, @intCast(i)), 1, 1, 1);
        }
        return map;
    }

    fn paintStarterTerrain(self: *GameMap) void {
        for (0..MapH) |y| {
            for (0..MapW) |x| {
                const ridge = (x > 13 and x < 18 and (y < 10 or y > 21));
                const water = (y == 15 and x > 9 and x < 23);
                self.terrain[y][x] = .{
                    .terrain_id = if (water) 3 else if (ridge) 2 else @as(u8, @intCast((x + y) % 3)),
                    .asset_id = if (water) 4 else @as(u16, @intCast((x + y) % 4)),
                    .walkable = !ridge and !water,
                    .buildable = !ridge and !water,
                    .movement_cost = if ((x + y) % 7 == 0) 2 else 1,
                    .height = if (ridge) 2 else 0,
                };
            }
        }
        self.version += 1;
    }

    pub fn inBounds(self: *const GameMap, x: i32, y: i32) bool {
        return x >= 0 and y >= 0 and @as(usize, @intCast(x)) < self.width and @as(usize, @intCast(y)) < self.height;
    }

    pub fn paintTerrain(self: *GameMap, x: i32, y: i32, terrain_id: u8, asset_id: u16, walkable: bool, movement_cost: u16) void {
        if (!self.inBounds(x, y)) return;
        const ux: usize = @intCast(x);
        const uy: usize = @intCast(y);
        self.terrain[uy][ux].terrain_id = terrain_id;
        self.terrain[uy][ux].asset_id = asset_id;
        self.terrain[uy][ux].walkable = walkable;
        self.terrain[uy][ux].buildable = walkable;
        self.terrain[uy][ux].movement_cost = @max(1, movement_cost);
        self.version += 1;
    }

    pub fn addObject(self: *GameMap, kind: ObjectKind, x: i32, y: i32, owner: u8, team: u8, asset_id: u16) ?u32 {
        if (!self.inBounds(x, y) or self.object_count >= MaxObjects) return null;
        const stats = defaultStats(kind);
        const id = self.next_object_id;
        self.next_object_id += 1;
        self.objects[self.object_count] = .{
            .id = id,
            .kind = kind,
            .x = x,
            .y = y,
            .owner = owner,
            .team = team,
            .hp = stats.hp,
            .max_hp = stats.hp,
            .asset_id = asset_id,
        };
        self.object_count += 1;
        self.version += 1;
        return id;
    }

    pub fn removeObjectAt(self: *GameMap, x: i32, y: i32) bool {
        var i: usize = 0;
        while (i < self.object_count) : (i += 1) {
            if (self.objects[i].x == x and self.objects[i].y == y) {
                self.objects[i] = self.objects[self.object_count - 1];
                self.object_count -= 1;
                self.version += 1;
                return true;
            }
        }
        return false;
    }

    pub fn objectAt(self: *GameMap, x: i32, y: i32) ?*MapObject {
        for (self.objects[0..self.object_count]) |*object| {
            if (object.x == x and object.y == y and object.active) return object;
        }
        return null;
    }

    pub fn findObject(self: *GameMap, kind: ObjectKind, team: u8) ?*MapObject {
        for (self.objects[0..self.object_count]) |*object| {
            if (object.kind == kind and object.team == team and object.active) return object;
        }
        return null;
    }

    pub fn rebuildGrid(self: *const GameMap, grid_map: *path_grid.GridMap) void {
        for (0..self.height) |y| {
            for (0..self.width) |x| {
                const cell = self.terrain[y][x];
                grid_map.tiles[y * self.width + x] = .{
                    .walkable = cell.walkable,
                    .movement_cost = cell.movement_cost,
                    .terrain_type = cell.terrain_id,
                    .blocks_vision = !cell.walkable,
                };
            }
        }
        for (self.objects[0..self.object_count]) |object| {
            if (!object.active) continue;
            switch (object.kind) {
                .obstacle, .citadel, .outpost, .defense_grid => {
                    if (grid_map.isInside(object.x, object.y)) {
                        grid_map.tiles[grid_map.index(object.x, object.y)].walkable = false;
                    }
                },
                else => {},
            }
        }
        grid_map.version = self.version;
    }
};

pub const ObjectStats = struct {
    hp: f32,
    range: f32,
    damage_per_second: f32,
    move_seconds: f32,
};

pub fn defaultStats(kind: ObjectKind) ObjectStats {
    return switch (kind) {
        .citadel => .{ .hp = 900, .range = 0, .damage_per_second = 0, .move_seconds = 999 },
        .imperator => .{ .hp = 420, .range = 7.0, .damage_per_second = 42, .move_seconds = 0.55 },
        .infantry => .{ .hp = 90, .range = 1.35, .damage_per_second = 12, .move_seconds = 0.30 },
        .captain => .{ .hp = 160, .range = 2.2, .damage_per_second = 18, .move_seconds = 0.38 },
        .artillery => .{ .hp = 120, .range = 4.8, .damage_per_second = 24, .move_seconds = 0.60 },
        .portal => .{ .hp = 260, .range = 0, .damage_per_second = 0, .move_seconds = 999 },
        .healing_pod => .{ .hp = 220, .range = 1.3, .damage_per_second = -20, .move_seconds = 999 },
        .obstacle => .{ .hp = 300, .range = 0, .damage_per_second = 0, .move_seconds = 999 },
        .outpost => .{ .hp = 360, .range = 3.2, .damage_per_second = 20, .move_seconds = 999 },
        .defense_grid => .{ .hp = 280, .range = 3.8, .damage_per_second = 22, .move_seconds = 999 },
    };
}
