const std = @import("std");

pub const TileCoord = struct {
    x: i32,
    y: i32,

    pub fn eql(a: TileCoord, b: TileCoord) bool {
        return a.x == b.x and a.y == b.y;
    }
};

pub const Direction = enum(u8) {
    none,
    north,
    south,
    west,
    east,
    north_west,
    north_east,
    south_west,
    south_east,

    pub fn delta(self: Direction) TileCoord {
        return switch (self) {
            .none => .{ .x = 0, .y = 0 },
            .north => .{ .x = 0, .y = -1 },
            .south => .{ .x = 0, .y = 1 },
            .west => .{ .x = -1, .y = 0 },
            .east => .{ .x = 1, .y = 0 },
            .north_west => .{ .x = -1, .y = -1 },
            .north_east => .{ .x = 1, .y = -1 },
            .south_west => .{ .x = -1, .y = 1 },
            .south_east => .{ .x = 1, .y = 1 },
        };
    }
};

pub fn directionFromDelta(dx: i32, dy: i32) Direction {
    if (dx == 0 and dy == 0) return .none;
    if (dx == 0 and dy < 0) return .north;
    if (dx == 0 and dy > 0) return .south;
    if (dx < 0 and dy == 0) return .west;
    if (dx > 0 and dy == 0) return .east;
    if (dx < 0 and dy < 0) return .north_west;
    if (dx > 0 and dy < 0) return .north_east;
    if (dx < 0 and dy > 0) return .south_west;
    return .south_east;
}

pub const MovementProfile = struct {
    terrain_mask: u32 = 0xffff_ffff,
    blocked_by_dynamic_units: bool = false,
    movement_cost_multiplier: u16 = 1,
    allow_diagonal_movement: bool = true,
    unit_radius: u8 = 0,
    footprint: u8 = 1,

    pub fn key(self: MovementProfile) u64 {
        var key_bits: u64 = self.terrain_mask;
        key_bits |= @as(u64, @intFromBool(self.blocked_by_dynamic_units)) << 32;
        key_bits |= @as(u64, @intFromBool(self.allow_diagonal_movement)) << 33;
        key_bits |= @as(u64, self.movement_cost_multiplier) << 34;
        key_bits |= @as(u64, self.unit_radius) << 50;
        key_bits |= @as(u64, self.footprint) << 56;
        return key_bits;
    }
};

pub const Tile = struct {
    walkable: bool = true,
    movement_cost: u16 = 1,
    terrain_type: u8 = 0,
    blocks_vision: bool = false,
};

pub const GridMap = struct {
    allocator: std.mem.Allocator,
    width: usize,
    height: usize,
    tiles: []Tile,
    version: u64 = 1,

    pub fn init(allocator: std.mem.Allocator, width: usize, height: usize) !GridMap {
        if (width == 0 or height == 0) return error.InvalidGridSize;
        const tiles = try allocator.alloc(Tile, width * height);
        @memset(tiles, .{});
        return .{
            .allocator = allocator,
            .width = width,
            .height = height,
            .tiles = tiles,
        };
    }

    pub fn deinit(self: *GridMap) void {
        self.allocator.free(self.tiles);
        self.* = undefined;
    }

    pub fn clone(self: *const GridMap, allocator: std.mem.Allocator) !GridMap {
        const tiles = try allocator.dupe(Tile, self.tiles);
        return .{
            .allocator = allocator,
            .width = self.width,
            .height = self.height,
            .tiles = tiles,
            .version = self.version,
        };
    }

    pub fn index(self: *const GridMap, x: i32, y: i32) usize {
        return @as(usize, @intCast(y)) * self.width + @as(usize, @intCast(x));
    }

    pub fn coordFromIndex(self: *const GridMap, idx: usize) TileCoord {
        return .{
            .x = @intCast(idx % self.width),
            .y = @intCast(idx / self.width),
        };
    }

    pub fn isInside(self: *const GridMap, x: i32, y: i32) bool {
        return x >= 0 and y >= 0 and @as(usize, @intCast(x)) < self.width and @as(usize, @intCast(y)) < self.height;
    }

    pub fn get(self: *const GridMap, x: i32, y: i32) ?Tile {
        if (!self.isInside(x, y)) return null;
        return self.tiles[self.index(x, y)];
    }

    pub fn setTile(self: *GridMap, x: i32, y: i32, tile: Tile) void {
        if (!self.isInside(x, y)) return;
        self.tiles[self.index(x, y)] = tile;
        self.version += 1;
    }

    pub fn setBlocked(self: *GridMap, x: i32, y: i32, blocked: bool) void {
        if (!self.isInside(x, y)) return;
        self.tiles[self.index(x, y)].walkable = !blocked;
        self.version += 1;
    }

    pub fn setCost(self: *GridMap, x: i32, y: i32, cost: u16) void {
        if (!self.isInside(x, y)) return;
        self.tiles[self.index(x, y)].movement_cost = @max(1, cost);
        self.version += 1;
    }

    pub fn setTerrain(self: *GridMap, x: i32, y: i32, terrain_type: u8) void {
        if (!self.isInside(x, y)) return;
        self.tiles[self.index(x, y)].terrain_type = terrain_type;
        self.version += 1;
    }

    pub fn isWalkableFor(self: *const GridMap, x: i32, y: i32, profile: MovementProfile) bool {
        if (!self.isInside(x, y)) return false;
        const footprint = @max(1, profile.footprint);
        const half: i32 = @intCast(footprint / 2);
        var oy: i32 = -half;
        while (oy <= half) : (oy += 1) {
            var ox: i32 = -half;
            while (ox <= half) : (ox += 1) {
                const tx = x + ox;
                const ty = y + oy;
                if (!self.isInside(tx, ty)) return false;
                const tile = self.tiles[self.index(tx, ty)];
                if (!tile.walkable) return false;
                const bit = @as(u32, 1) << @as(u5, @intCast(tile.terrain_type & 31));
                if ((profile.terrain_mask & bit) == 0) return false;
            }
        }
        return true;
    }

    pub fn movementCost(self: *const GridMap, x: i32, y: i32, profile: MovementProfile) u32 {
        if (!self.isInside(x, y)) return std.math.maxInt(u32) / 4;
        const cost = @max(1, self.tiles[self.index(x, y)].movement_cost);
        return @as(u32, cost) * @as(u32, @max(1, profile.movement_cost_multiplier));
    }
};

pub const CardinalDirections = [_]Direction{ .north, .south, .west, .east };
pub const DiagonalDirections = [_]Direction{ .north_west, .north_east, .south_west, .south_east };

