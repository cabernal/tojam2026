const std = @import("std");
const grid = @import("grid_map.zig");
const flow_mod = @import("flow_field.zig");

pub const RouteCacheEntry = struct {
    start_sector: usize,
    goal_sector: usize,
    profile_key: u64,
    map_version: u64,
    route: []usize,
};

pub const FlowCacheEntry = struct {
    target: grid.TileCoord,
    sector_id: usize,
    profile_key: u64,
    map_version: u64,
    field: flow_mod.FlowField,
};

pub const PathCache = struct {
    allocator: std.mem.Allocator,
    routes: std.ArrayList(RouteCacheEntry) = .empty,
    flows: std.ArrayList(FlowCacheEntry) = .empty,
    route_hits: usize = 0,
    route_misses: usize = 0,
    flow_hits: usize = 0,
    flow_misses: usize = 0,

    pub fn init(allocator: std.mem.Allocator) PathCache {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *PathCache) void {
        self.clear();
        self.routes.deinit(self.allocator);
        self.flows.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn clear(self: *PathCache) void {
        for (self.routes.items) |entry| self.allocator.free(entry.route);
        for (self.flows.items) |*entry| entry.field.deinit();
        self.routes.clearRetainingCapacity();
        self.flows.clearRetainingCapacity();
    }

    pub fn invalidateChangedVersion(self: *PathCache, map_version: u64) void {
        var i: usize = 0;
        while (i < self.routes.items.len) {
            if (self.routes.items[i].map_version == map_version) {
                i += 1;
            } else {
                self.allocator.free(self.routes.items[i].route);
                _ = self.routes.orderedRemove(i);
            }
        }
        i = 0;
        while (i < self.flows.items.len) {
            if (self.flows.items[i].map_version == map_version) {
                i += 1;
            } else {
                self.flows.items[i].field.deinit();
                _ = self.flows.orderedRemove(i);
            }
        }
    }

    pub fn getRoute(
        self: *PathCache,
        start_sector: usize,
        goal_sector: usize,
        profile_key: u64,
        map_version: u64,
    ) ?[]const usize {
        for (self.routes.items) |entry| {
            if (entry.start_sector == start_sector and entry.goal_sector == goal_sector and entry.profile_key == profile_key and entry.map_version == map_version) {
                self.route_hits += 1;
                return entry.route;
            }
        }
        self.route_misses += 1;
        return null;
    }

    pub fn putRoute(
        self: *PathCache,
        start_sector: usize,
        goal_sector: usize,
        profile_key: u64,
        map_version: u64,
        route: []const usize,
    ) !void {
        const clone = try self.allocator.dupe(usize, route);
        errdefer self.allocator.free(clone);
        try self.routes.append(self.allocator, .{
            .start_sector = start_sector,
            .goal_sector = goal_sector,
            .profile_key = profile_key,
            .map_version = map_version,
            .route = clone,
        });
    }

    pub fn getFlow(
        self: *PathCache,
        target: grid.TileCoord,
        sector_id: usize,
        profile_key: u64,
        map_version: u64,
    ) ?*flow_mod.FlowField {
        for (self.flows.items) |*entry| {
            if (entry.target.eql(target) and entry.sector_id == sector_id and entry.profile_key == profile_key and entry.map_version == map_version) {
                self.flow_hits += 1;
                return &entry.field;
            }
        }
        self.flow_misses += 1;
        return null;
    }

    pub fn putFlow(self: *PathCache, field: flow_mod.FlowField) !*flow_mod.FlowField {
        try self.flows.append(self.allocator, .{
            .target = field.target,
            .sector_id = field.sector_id,
            .profile_key = field.profile_key,
            .map_version = field.map_version,
            .field = field,
        });
        return &self.flows.items[self.flows.items.len - 1].field;
    }
};

test "cache reuses routes and invalidates by version" {
    var cache = PathCache.init(std.testing.allocator);
    defer cache.deinit();

    try cache.putRoute(0, 1, 7, 2, &.{ 3, 4 });
    try std.testing.expect(cache.getRoute(0, 1, 7, 2) != null);
    try std.testing.expectEqual(@as(usize, 1), cache.route_hits);
    cache.invalidateChangedVersion(3);
    try std.testing.expect(cache.getRoute(0, 1, 7, 2) == null);
}

