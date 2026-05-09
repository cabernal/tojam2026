const std = @import("std");
const map_mod = @import("../map/map.zig");
const path = @import("../pathfinding/mod.zig");

pub const Phase = enum {
    setup_player_one,
    setup_player_two,
    playing,
    game_over,
};

pub const Simulation = struct {
    phase: Phase = .setup_player_one,
    winner: ?u8 = null,
    step_timer: f32 = 0,

    pub fn resetSetup(self: *Simulation) void {
        self.phase = .setup_player_one;
        self.winner = null;
        self.step_timer = 0;
    }

    pub fn startPlaying(self: *Simulation) void {
        self.phase = .playing;
        self.winner = null;
        self.step_timer = 0;
    }

    pub fn togglePlay(self: *Simulation) void {
        switch (self.phase) {
            .setup_player_one => self.phase = .setup_player_two,
            .setup_player_two => self.startPlaying(),
            .playing, .game_over => self.resetSetup(),
        }
    }

    pub fn activeSetupPlayer(self: *const Simulation) ?u8 {
        return switch (self.phase) {
            .setup_player_one => 0,
            .setup_player_two => 1,
            else => null,
        };
    }

    pub fn placementPlayer(self: *const Simulation, requested_player: u8) u8 {
        return self.activeSetupPlayer() orelse requested_player;
    }

    pub fn canPlaceObject(self: *const Simulation, game_map: *const map_mod.GameMap, kind: map_mod.ObjectKind, player: u8) bool {
        const setup_player = self.activeSetupPlayer() orelse return true;
        if (player != setup_player) return false;
        var matching: usize = 0;
        var mobile_units: usize = 0;
        var static_structures: usize = 0;
        for (game_map.objects[0..game_map.object_count]) |object| {
            if (!object.active or object.team != player) continue;
            if (object.kind == kind) matching += 1;
            switch (object.kind) {
                .infantry, .captain, .artillery => mobile_units += 1,
                .outpost, .defense_grid => static_structures += 1,
                else => {},
            }
        }
        return switch (kind) {
            .citadel, .imperator => matching < 1,
            .infantry, .captain, .artillery => mobile_units < 14,
            .portal, .healing_pod => matching < 2,
            .outpost, .defense_grid => static_structures < 4,
            .obstacle => matching < 12,
        };
    }

    pub fn update(
        self: *Simulation,
        game_map: *map_mod.GameMap,
        grid_map: *path.GridMap,
        pathfinder: *path.HierarchicalPathfinder,
        dt: f32,
    ) void {
        if (self.phase != .playing) return;
        self.step_timer += dt;
        self.resolveCombat(game_map, dt);
        if (self.checkGameOver(game_map)) return;
        if (self.step_timer >= 0.24) {
            self.step_timer = 0;
            self.moveUnits(game_map, grid_map, pathfinder);
        }
    }

    fn resolveCombat(self: *Simulation, game_map: *map_mod.GameMap, dt: f32) void {
        _ = self;
        var i: usize = 0;
        while (i < game_map.object_count) : (i += 1) {
            if (!game_map.objects[i].active) continue;
            const attacker = game_map.objects[i];
            const stats = map_mod.defaultStats(attacker.kind);
            if (stats.damage_per_second <= 0) continue;

            var target_idx: ?usize = null;
            var best_dist: f32 = 9999;
            for (game_map.objects[0..game_map.object_count], 0..) |target, j| {
                if (!target.active or target.team == attacker.team) continue;
                const dx: f32 = @floatFromInt(attacker.x - target.x);
                const dy: f32 = @floatFromInt(attacker.y - target.y);
                const d = @sqrt(dx * dx + dy * dy);
                if (d <= stats.range and d < best_dist) {
                    target_idx = j;
                    best_dist = d;
                }
            }
            if (target_idx) |j| {
                game_map.objects[j].hp = @max(0, game_map.objects[j].hp - stats.damage_per_second * dt);
                if (game_map.objects[j].hp <= 0) {
                    game_map.objects[j].active = false;
                    game_map.version += 1;
                }
            }
        }
    }

    fn moveUnits(self: *Simulation, game_map: *map_mod.GameMap, grid_map: *path.GridMap, pathfinder: *path.HierarchicalPathfinder) void {
        _ = self;
        const profile = path.MovementProfile{ .allow_diagonal_movement = true };
        game_map.rebuildGrid(grid_map);
        var i: usize = 0;
        while (i < game_map.object_count) : (i += 1) {
            var object = &game_map.objects[i];
            if (!object.active) continue;
            switch (object.kind) {
                .infantry, .captain, .artillery, .imperator => {},
                else => continue,
            }
            const target_team: u8 = if (object.team == 0) 1 else 0;
            const target = game_map.findObject(.citadel, target_team) orelse continue;
            const start = path.TileCoord{ .x = object.x, .y = object.y };
            const goal = approachTile(grid_map, target.*, profile) orelse continue;
            const sector_id = path.sector.sectorIdForCoord(grid_map, pathfinder.sector_size, start) orelse continue;
            const field = pathfinder.getFlowField(grid_map, goal, sector_id, profile) catch {
                var route = pathfinder.findPath(grid_map, start, goal, profile) catch continue;
                defer route.deinit();
                if (route.tiles.len >= 2 and canStepInto(game_map, route.tiles[1], object.id)) {
                    object.x = route.tiles[1].x;
                    object.y = route.tiles[1].y;
                    game_map.version += 1;
                }
                continue;
            };
            const direction = field.directionAt(grid_map, start);
            const delta = direction.delta();
            const next = path.TileCoord{ .x = object.x + delta.x, .y = object.y + delta.y };
            if (direction != .none and grid_map.isWalkableFor(next.x, next.y, profile) and canStepInto(game_map, next, object.id)) {
                object.x = next.x;
                object.y = next.y;
                game_map.version += 1;
            }
        }
    }

    fn checkGameOver(self: *Simulation, game_map: *map_mod.GameMap) bool {
        const p0 = game_map.findObject(.imperator, 0);
        const p1 = game_map.findObject(.imperator, 1);
        if (p0 == null or !p0.?.active) {
            self.phase = .game_over;
            self.winner = 1;
            return true;
        }
        if (p1 == null or !p1.?.active) {
            self.phase = .game_over;
            self.winner = 0;
            return true;
        }
        return false;
    }
};

fn approachTile(grid_map: *const path.GridMap, target: map_mod.MapObject, profile: path.MovementProfile) ?path.TileCoord {
    const target_coord = path.TileCoord{ .x = target.x, .y = target.y };
    if (grid_map.isWalkableFor(target_coord.x, target_coord.y, profile)) return target_coord;
    var radius: i32 = 1;
    while (radius <= 5) : (radius += 1) {
        var y = target.y - radius;
        while (y <= target.y + radius) : (y += 1) {
            var x = target.x - radius;
            while (x <= target.x + radius) : (x += 1) {
                if (@max(@abs(x - target.x), @abs(y - target.y)) != radius) continue;
                if (!grid_map.isWalkableFor(x, y, profile)) continue;
                return .{ .x = x, .y = y };
            }
        }
    }
    return null;
}

fn canStepInto(game_map: *map_mod.GameMap, coord: path.TileCoord, moving_id: u32) bool {
    if (game_map.objectAt(coord.x, coord.y)) |object| {
        return object.id == moving_id;
    }
    return true;
}

test "units move toward a walkable approach tile around blocked citadels" {
    var grid = try path.GridMap.init(std.testing.allocator, map_mod.MapW, map_mod.MapH);
    defer grid.deinit();
    var game_map = map_mod.GameMap.initDefault();
    game_map.rebuildGrid(&grid);
    var pathfinder = path.HierarchicalPathfinder.init(std.testing.allocator, 8);
    defer pathfinder.deinit();
    try pathfinder.build(&grid, .{ .allow_diagonal_movement = true });

    var sim: Simulation = .{};
    sim.startPlaying();
    const before = game_map.objects[18];
    sim.update(&game_map, &grid, &pathfinder, 0.25);
    const after = game_map.objects[18];
    try std.testing.expect(before.x != after.x or before.y != after.y);
    try std.testing.expect(pathfinder.getDebugData().flow_cache_misses > 0);
}
