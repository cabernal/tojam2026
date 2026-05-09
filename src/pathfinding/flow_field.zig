const std = @import("std");
const grid = @import("grid_map.zig");

pub const InfiniteCost = std.math.maxInt(u32) / 4;

pub const FlowField = struct {
    allocator: std.mem.Allocator,
    width: usize,
    height: usize,
    target: grid.TileCoord,
    sector_id: usize,
    profile_key: u64,
    map_version: u64,
    integration: []u32,
    directions: []grid.Direction,

    pub fn init(
        allocator: std.mem.Allocator,
        map: *const grid.GridMap,
        target: grid.TileCoord,
        sector_id: usize,
        profile: grid.MovementProfile,
    ) !FlowField {
        const len = map.width * map.height;
        const integration = try allocator.alloc(u32, len);
        errdefer allocator.free(integration);
        const directions = try allocator.alloc(grid.Direction, len);
        errdefer allocator.free(directions);
        @memset(integration, InfiniteCost);
        @memset(directions, .none);
        return .{
            .allocator = allocator,
            .width = map.width,
            .height = map.height,
            .target = target,
            .sector_id = sector_id,
            .profile_key = profile.key(),
            .map_version = map.version,
            .integration = integration,
            .directions = directions,
        };
    }

    pub fn deinit(self: *FlowField) void {
        self.allocator.free(self.integration);
        self.allocator.free(self.directions);
        self.* = undefined;
    }

    pub fn compute(self: *FlowField, map: *const grid.GridMap, profile: grid.MovementProfile) !void {
        if (!map.isWalkableFor(self.target.x, self.target.y, profile)) return error.NoPath;
        const len = map.width * map.height;
        var settled = try self.allocator.alloc(bool, len);
        defer self.allocator.free(settled);
        @memset(settled, false);

        const target_idx = map.index(self.target.x, self.target.y);
        self.integration[target_idx] = 0;

        while (true) {
            var best_idx: usize = std.math.maxInt(usize);
            var best_cost: u32 = InfiniteCost;
            for (self.integration, 0..) |cost, idx| {
                if (!settled[idx] and cost < best_cost) {
                    best_idx = idx;
                    best_cost = cost;
                }
            }
            if (best_idx == std.math.maxInt(usize)) break;
            settled[best_idx] = true;
            const current = map.coordFromIndex(best_idx);

            for (grid.CardinalDirections) |dir| {
                const d = dir.delta();
                const nx = current.x + d.x;
                const ny = current.y + d.y;
                if (!map.isWalkableFor(nx, ny, profile)) continue;
                const nidx = map.index(nx, ny);
                const candidate = best_cost + 10 * map.movementCost(nx, ny, profile);
                if (candidate < self.integration[nidx]) {
                    self.integration[nidx] = candidate;
                }
            }
            if (profile.allow_diagonal_movement) {
                for (grid.DiagonalDirections) |dir| {
                    const d = dir.delta();
                    const nx = current.x + d.x;
                    const ny = current.y + d.y;
                    if (!map.isWalkableFor(nx, ny, profile)) continue;
                    const nidx = map.index(nx, ny);
                    const candidate = best_cost + 14 * map.movementCost(nx, ny, profile);
                    if (candidate < self.integration[nidx]) {
                        self.integration[nidx] = candidate;
                    }
                }
            }
        }

        for (self.directions, 0..) |*direction, idx| {
            const coord = map.coordFromIndex(idx);
            if (!map.isWalkableFor(coord.x, coord.y, profile) or self.integration[idx] == InfiniteCost) {
                direction.* = .none;
                continue;
            }
            var best_dir: grid.Direction = .none;
            var best_cost = self.integration[idx];
            for (grid.CardinalDirections) |dir| {
                const d = dir.delta();
                const nx = coord.x + d.x;
                const ny = coord.y + d.y;
                if (!map.isInside(nx, ny)) continue;
                const nidx = map.index(nx, ny);
                if (self.integration[nidx] < best_cost) {
                    best_cost = self.integration[nidx];
                    best_dir = dir;
                }
            }
            if (profile.allow_diagonal_movement) {
                for (grid.DiagonalDirections) |dir| {
                    const d = dir.delta();
                    const nx = coord.x + d.x;
                    const ny = coord.y + d.y;
                    if (!map.isInside(nx, ny)) continue;
                    const nidx = map.index(nx, ny);
                    if (self.integration[nidx] < best_cost) {
                        best_cost = self.integration[nidx];
                        best_dir = dir;
                    }
                }
            }
            direction.* = best_dir;
        }
    }

    pub fn directionAt(self: *const FlowField, map: *const grid.GridMap, coord: grid.TileCoord) grid.Direction {
        if (!map.isInside(coord.x, coord.y)) return .none;
        return self.directions[map.index(coord.x, coord.y)];
    }
};

test "flow field points toward target around blocked tiles" {
    var g = try grid.GridMap.init(std.testing.allocator, 5, 3);
    defer g.deinit();
    g.setBlocked(2, 1, true);

    var field = try FlowField.init(std.testing.allocator, &g, .{ .x = 4, .y = 1 }, 0, .{ .allow_diagonal_movement = false });
    defer field.deinit();
    try field.compute(&g, .{ .allow_diagonal_movement = false });

    try std.testing.expect(field.directionAt(&g, .{ .x = 0, .y = 1 }) != .none);
    try std.testing.expectEqual(grid.Direction.none, field.directionAt(&g, .{ .x = 2, .y = 1 }));
}

