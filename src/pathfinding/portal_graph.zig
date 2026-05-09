const std = @import("std");
const grid = @import("grid_map.zig");
const sector_mod = @import("sector.zig");

pub const Portal = struct {
    id: usize,
    sector_a: usize,
    sector_b: usize,
    tile_a: grid.TileCoord,
    tile_b: grid.TileCoord,

    pub fn includesSector(self: Portal, sector_id: usize) bool {
        return self.sector_a == sector_id or self.sector_b == sector_id;
    }

    pub fn endpointForSector(self: Portal, sector_id: usize) ?grid.TileCoord {
        if (self.sector_a == sector_id) return self.tile_a;
        if (self.sector_b == sector_id) return self.tile_b;
        return null;
    }
};

pub const Edge = struct {
    from: usize,
    to: usize,
    cost: u32,
};

pub const PortalGraph = struct {
    allocator: std.mem.Allocator,
    portals: []Portal = &.{},
    edges: []Edge = &.{},
    map_version: u64 = 0,

    pub fn init(allocator: std.mem.Allocator) PortalGraph {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *PortalGraph) void {
        self.allocator.free(self.portals);
        self.allocator.free(self.edges);
        self.* = undefined;
    }

    pub fn clear(self: *PortalGraph) void {
        self.allocator.free(self.portals);
        self.allocator.free(self.edges);
        self.portals = &.{};
        self.edges = &.{};
        self.map_version = 0;
    }

    pub fn build(
        self: *PortalGraph,
        map: *const grid.GridMap,
        sectors: []const sector_mod.Sector,
        sector_size: usize,
        profile: grid.MovementProfile,
    ) !void {
        self.clear();
        var portals: std.ArrayList(Portal) = .empty;
        errdefer portals.deinit(self.allocator);

        const col_count = sector_mod.columns(map.width, sector_size);
        for (sectors) |s| {
            const sx = s.id % col_count;
            const sy = s.id / col_count;

            if (sx + 1 < col_count) {
                const east_id = s.id + 1;
                const x_a = s.x + s.width - 1;
                const x_b = x_a + 1;
                var y = s.y;
                while (y < s.y + s.height) : (y += 1) {
                    if (map.isWalkableFor(x_a, y, profile) and map.isWalkableFor(x_b, y, profile)) {
                        try portals.append(self.allocator, .{
                            .id = portals.items.len,
                            .sector_a = s.id,
                            .sector_b = east_id,
                            .tile_a = .{ .x = x_a, .y = y },
                            .tile_b = .{ .x = x_b, .y = y },
                        });
                    }
                }
            }

            const south_id = s.id + col_count;
            if (sy + 1 < (sectors.len + col_count - 1) / col_count and south_id < sectors.len) {
                const y_a = s.y + s.height - 1;
                const y_b = y_a + 1;
                var x = s.x;
                while (x < s.x + s.width) : (x += 1) {
                    if (map.isWalkableFor(x, y_a, profile) and map.isWalkableFor(x, y_b, profile)) {
                        try portals.append(self.allocator, .{
                            .id = portals.items.len,
                            .sector_a = s.id,
                            .sector_b = south_id,
                            .tile_a = .{ .x = x, .y = y_a },
                            .tile_b = .{ .x = x, .y = y_b },
                        });
                    }
                }
            }
        }

        self.portals = try portals.toOwnedSlice(self.allocator);
        try self.buildEdges(map, sectors, profile);
        self.map_version = map.version;
    }

    fn buildEdges(
        self: *PortalGraph,
        map: *const grid.GridMap,
        sectors: []const sector_mod.Sector,
        profile: grid.MovementProfile,
    ) !void {
        var edges: std.ArrayList(Edge) = .empty;
        errdefer edges.deinit(self.allocator);

        for (self.portals, 0..) |a, ai| {
            for (self.portals, 0..) |b, bi| {
                if (ai == bi) continue;
                if (sharedSector(a, b)) |sector_id| {
                    const sector = sectors[sector_id];
                    const from = a.endpointForSector(sector_id).?;
                    const to = b.endpointForSector(sector_id).?;
                    if (reachableInSector(self.allocator, map, sector, from, to, profile)) {
                        const cost = manhattan(from, to) * 10 + 10;
                        try edges.append(self.allocator, .{ .from = ai, .to = bi, .cost = cost });
                    }
                }
            }
        }

        self.edges = try edges.toOwnedSlice(self.allocator);
    }
};

fn sharedSector(a: Portal, b: Portal) ?usize {
    if (a.sector_a == b.sector_a or a.sector_a == b.sector_b) return a.sector_a;
    if (a.sector_b == b.sector_a or a.sector_b == b.sector_b) return a.sector_b;
    return null;
}

fn manhattan(a: grid.TileCoord, b: grid.TileCoord) u32 {
    return @intCast(@abs(a.x - b.x) + @abs(a.y - b.y));
}

fn reachableInSector(
    allocator: std.mem.Allocator,
    map: *const grid.GridMap,
    sector: sector_mod.Sector,
    start: grid.TileCoord,
    goal: grid.TileCoord,
    profile: grid.MovementProfile,
) bool {
    if (start.eql(goal)) return true;
    const len: usize = @intCast(sector.width * sector.height);
    var visited = allocator.alloc(bool, len) catch return false;
    defer allocator.free(visited);
    @memset(visited, false);

    var queue = allocator.alloc(grid.TileCoord, len) catch return false;
    defer allocator.free(queue);
    var head: usize = 0;
    var tail: usize = 0;

    queue[tail] = start;
    tail += 1;
    visited[sectorLocalIndex(sector, start)] = true;

    while (head < tail) {
        const current = queue[head];
        head += 1;
        for (grid.CardinalDirections) |dir| {
            const d = dir.delta();
            const next = grid.TileCoord{ .x = current.x + d.x, .y = current.y + d.y };
            if (!sector.contains(next) or !map.isWalkableFor(next.x, next.y, profile)) continue;
            const idx = sectorLocalIndex(sector, next);
            if (visited[idx]) continue;
            if (next.eql(goal)) return true;
            visited[idx] = true;
            queue[tail] = next;
            tail += 1;
        }
    }
    return false;
}

fn sectorLocalIndex(sector: sector_mod.Sector, coord: grid.TileCoord) usize {
    return @as(usize, @intCast(coord.y - sector.y)) * @as(usize, @intCast(sector.width)) +
        @as(usize, @intCast(coord.x - sector.x));
}

test "portal detection and graph connectivity" {
    var g = try grid.GridMap.init(std.testing.allocator, 8, 4);
    defer g.deinit();
    const sectors = try sector_mod.buildSectors(std.testing.allocator, &g, 4);
    defer std.testing.allocator.free(sectors);

    var graph = PortalGraph.init(std.testing.allocator);
    defer graph.deinit();
    try graph.build(&g, sectors, 4, .{ .allow_diagonal_movement = false });

    try std.testing.expect(graph.portals.len >= 4);
    try std.testing.expect(graph.edges.len > 0);
}

