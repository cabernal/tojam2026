const std = @import("std");
const grid = @import("grid_map.zig");
const portal_graph = @import("portal_graph.zig");

pub const Path = struct {
    tiles: []grid.TileCoord,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Path) void {
        self.allocator.free(self.tiles);
        self.* = undefined;
    }
};

pub const PortalRoute = struct {
    portal_ids: []usize,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *PortalRoute) void {
        self.allocator.free(self.portal_ids);
        self.* = undefined;
    }
};

fn heuristic(a: grid.TileCoord, b: grid.TileCoord, diagonal: bool) u32 {
    const dx: u32 = @intCast(@abs(a.x - b.x));
    const dy: u32 = @intCast(@abs(a.y - b.y));
    if (diagonal) {
        const min_d = @min(dx, dy);
        const max_d = @max(dx, dy);
        return 14 * min_d + 10 * (max_d - min_d);
    }
    return 10 * (dx + dy);
}

fn lowestOpen(open: []const usize, f_score: []const u32) usize {
    var best: usize = 0;
    var best_score = f_score[open[0]];
    for (open[1..], 1..) |idx, i| {
        if (f_score[idx] < best_score) {
            best = i;
            best_score = f_score[idx];
        }
    }
    return best;
}

fn addNeighbors(
    comptime diagonal: bool,
    list: *std.ArrayList(grid.Direction),
    allocator: std.mem.Allocator,
) !void {
    for (grid.CardinalDirections) |dir| try list.append(allocator, dir);
    if (diagonal) {
        for (grid.DiagonalDirections) |dir| try list.append(allocator, dir);
    }
}

pub fn findGridPath(
    allocator: std.mem.Allocator,
    map: *const grid.GridMap,
    start: grid.TileCoord,
    goal: grid.TileCoord,
    profile: grid.MovementProfile,
) !Path {
    if (!map.isWalkableFor(start.x, start.y, profile) or !map.isWalkableFor(goal.x, goal.y, profile)) {
        return error.NoPath;
    }

    const count = map.width * map.height;
    const sentinel = std.math.maxInt(usize);
    const inf = std.math.maxInt(u32) / 4;

    var g_score = try allocator.alloc(u32, count);
    defer allocator.free(g_score);
    var f_score = try allocator.alloc(u32, count);
    defer allocator.free(f_score);
    var came_from = try allocator.alloc(usize, count);
    defer allocator.free(came_from);
    var closed = try allocator.alloc(bool, count);
    defer allocator.free(closed);
    @memset(g_score, inf);
    @memset(f_score, inf);
    @memset(came_from, sentinel);
    @memset(closed, false);

    var open: std.ArrayList(usize) = .empty;
    defer open.deinit(allocator);

    const start_idx = map.index(start.x, start.y);
    const goal_idx = map.index(goal.x, goal.y);
    g_score[start_idx] = 0;
    f_score[start_idx] = heuristic(start, goal, profile.allow_diagonal_movement);
    try open.append(allocator, start_idx);

    var dirs: std.ArrayList(grid.Direction) = .empty;
    defer dirs.deinit(allocator);
    try addNeighbors(false, &dirs, allocator);
    if (profile.allow_diagonal_movement) {
        for (grid.DiagonalDirections) |dir| try dirs.append(allocator, dir);
    }

    while (open.items.len > 0) {
        const open_pos = lowestOpen(open.items, f_score);
        const current_idx = open.orderedRemove(open_pos);
        if (current_idx == goal_idx) break;
        if (closed[current_idx]) continue;
        closed[current_idx] = true;

        const current = map.coordFromIndex(current_idx);
        for (dirs.items) |dir| {
            const delta = dir.delta();
            const nx = current.x + delta.x;
            const ny = current.y + delta.y;
            if (!map.isWalkableFor(nx, ny, profile)) continue;
            if (delta.x != 0 and delta.y != 0) {
                if (!map.isWalkableFor(current.x + delta.x, current.y, profile)) continue;
                if (!map.isWalkableFor(current.x, current.y + delta.y, profile)) continue;
            }

            const next_idx = map.index(nx, ny);
            if (closed[next_idx]) continue;
            const step_base: u32 = if (delta.x != 0 and delta.y != 0) 14 else 10;
            const tentative = g_score[current_idx] + step_base * map.movementCost(nx, ny, profile);
            if (tentative >= g_score[next_idx]) continue;

            came_from[next_idx] = current_idx;
            g_score[next_idx] = tentative;
            f_score[next_idx] = tentative + heuristic(.{ .x = nx, .y = ny }, goal, profile.allow_diagonal_movement);
            try open.append(allocator, next_idx);
        }
    }

    if (start_idx != goal_idx and came_from[goal_idx] == sentinel) return error.NoPath;

    var reversed: std.ArrayList(grid.TileCoord) = .empty;
    errdefer reversed.deinit(allocator);
    var cursor = goal_idx;
    while (true) {
        try reversed.append(allocator, map.coordFromIndex(cursor));
        if (cursor == start_idx) break;
        cursor = came_from[cursor];
        if (cursor == sentinel) return error.NoPath;
    }
    std.mem.reverse(grid.TileCoord, reversed.items);
    return .{
        .tiles = try reversed.toOwnedSlice(allocator),
        .allocator = allocator,
    };
}

pub fn findPortalRoute(
    allocator: std.mem.Allocator,
    graph: *const portal_graph.PortalGraph,
    start_sector: usize,
    goal_sector: usize,
) !PortalRoute {
    if (start_sector == goal_sector) {
        return .{ .portal_ids = try allocator.alloc(usize, 0), .allocator = allocator };
    }
    if (graph.portals.len == 0) return error.NoPath;

    const count = graph.portals.len;
    const inf = std.math.maxInt(u32) / 4;
    const sentinel = std.math.maxInt(usize);

    var dist = try allocator.alloc(u32, count);
    defer allocator.free(dist);
    var came_from = try allocator.alloc(usize, count);
    defer allocator.free(came_from);
    var closed = try allocator.alloc(bool, count);
    defer allocator.free(closed);
    @memset(dist, inf);
    @memset(came_from, sentinel);
    @memset(closed, false);

    var open: std.ArrayList(usize) = .empty;
    defer open.deinit(allocator);

    for (graph.portals, 0..) |portal, i| {
        if (portal.includesSector(start_sector)) {
            dist[i] = 0;
            try open.append(allocator, i);
        }
    }
    if (open.items.len == 0) return error.NoPath;

    var found: usize = sentinel;
    while (open.items.len > 0) {
        const open_pos = lowestOpen(open.items, dist);
        const current = open.orderedRemove(open_pos);
        if (closed[current]) continue;
        closed[current] = true;

        if (graph.portals[current].includesSector(goal_sector)) {
            found = current;
            break;
        }

        for (graph.edges) |edge| {
            if (edge.from != current) continue;
            if (closed[edge.to]) continue;
            const tentative = dist[current] + edge.cost;
            if (tentative >= dist[edge.to]) continue;
            dist[edge.to] = tentative;
            came_from[edge.to] = current;
            try open.append(allocator, edge.to);
        }
    }

    if (found == sentinel) return error.NoPath;

    var reversed: std.ArrayList(usize) = .empty;
    errdefer reversed.deinit(allocator);
    var cursor = found;
    while (true) {
        try reversed.append(allocator, cursor);
        if (came_from[cursor] == sentinel) break;
        cursor = came_from[cursor];
    }
    std.mem.reverse(usize, reversed.items);
    return .{ .portal_ids = try reversed.toOwnedSlice(allocator), .allocator = allocator };
}

test "A* routes around obstacles" {
    var g = try grid.GridMap.init(std.testing.allocator, 8, 5);
    defer g.deinit();
    for (0..4) |y| g.setBlocked(3, @intCast(y), true);

    var path = try findGridPath(
        std.testing.allocator,
        &g,
        .{ .x = 1, .y = 1 },
        .{ .x = 6, .y = 1 },
        .{ .allow_diagonal_movement = false },
    );
    defer path.deinit();

    try std.testing.expect(path.tiles.len > 6);
    for (path.tiles) |tile| {
        try std.testing.expect(!(tile.x == 3 and tile.y < 4));
    }
}

test "movement profiles reject masked terrain" {
    var g = try grid.GridMap.init(std.testing.allocator, 4, 2);
    defer g.deinit();
    g.setTerrain(1, 0, 2);
    g.setTerrain(2, 0, 2);
    g.setTerrain(1, 1, 2);
    g.setTerrain(2, 1, 2);

    const profile = grid.MovementProfile{
        .allow_diagonal_movement = false,
        .terrain_mask = 0b0011,
    };
    try std.testing.expectError(
        error.NoPath,
        findGridPath(std.testing.allocator, &g, .{ .x = 0, .y = 0 }, .{ .x = 3, .y = 0 }, profile),
    );
}
