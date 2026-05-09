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
        self.resolveHealing(game_map, dt);
        if (self.checkGameOver(game_map)) return;
        if (self.step_timer >= 0.24) {
            self.step_timer = 0;
            self.moveUnits(game_map, grid_map, pathfinder);
            self.resolvePortals(game_map, grid_map);
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

    fn resolveHealing(self: *Simulation, game_map: *map_mod.GameMap, dt: f32) void {
        _ = self;
        for (game_map.objects[0..game_map.object_count]) |pod| {
            if (!pod.active or pod.kind != .healing_pod) continue;
            const stats = map_mod.defaultStats(.healing_pod);
            const heal_per_second = -stats.damage_per_second;
            if (heal_per_second <= 0) continue;
            for (game_map.objects[0..game_map.object_count]) |*target| {
                if (!target.active or target.team != pod.team or target.id == pod.id) continue;
                if (target.hp >= target.max_hp) continue;
                const dx: f32 = @floatFromInt(pod.x - target.x);
                const dy: f32 = @floatFromInt(pod.y - target.y);
                const d = @sqrt(dx * dx + dy * dy);
                if (d <= stats.range) {
                    target.hp = @min(target.max_hp, target.hp + heal_per_second * dt);
                    game_map.version += 1;
                }
            }
        }
    }

    fn resolvePortals(self: *Simulation, game_map: *map_mod.GameMap, grid_map: *path.GridMap) void {
        _ = self;
        const profile = path.MovementProfile{ .allow_diagonal_movement = true };
        for (game_map.objects[0..game_map.object_count]) |*unit| {
            if (!unit.active or !isMobileUnit(unit.kind)) continue;
            const source = portalAt(game_map, unit.x, unit.y) orelse continue;
            const target = linkedPortal(game_map, source.*) orelse continue;
            const exit = portalExitTile(game_map, grid_map, target.*, unit.id, profile) orelse continue;
            unit.x = exit.x;
            unit.y = exit.y;
            game_map.version += 1;
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
        return object.id == moving_id or object.kind == .portal or object.kind == .healing_pod;
    }
    return true;
}

fn isMobileUnit(kind: map_mod.ObjectKind) bool {
    return switch (kind) {
        .infantry, .captain, .artillery, .imperator => true,
        else => false,
    };
}

fn portalAt(game_map: *map_mod.GameMap, x: i32, y: i32) ?*map_mod.MapObject {
    for (game_map.objects[0..game_map.object_count]) |*object| {
        if (object.active and object.kind == .portal and object.x == x and object.y == y) return object;
    }
    return null;
}

fn linkedPortal(game_map: *map_mod.GameMap, source: map_mod.MapObject) ?*map_mod.MapObject {
    var fallback: ?*map_mod.MapObject = null;
    for (game_map.objects[0..game_map.object_count]) |*object| {
        if (!object.active or object.kind != .portal or object.id == source.id) continue;
        if (object.team == source.team) return object;
        if (fallback == null) fallback = object;
    }
    return fallback;
}

fn portalExitTile(
    game_map: *map_mod.GameMap,
    grid_map: *path.GridMap,
    portal: map_mod.MapObject,
    moving_id: u32,
    profile: path.MovementProfile,
) ?path.TileCoord {
    var radius: i32 = 1;
    while (radius <= 3) : (radius += 1) {
        var y = portal.y - radius;
        while (y <= portal.y + radius) : (y += 1) {
            var x = portal.x - radius;
            while (x <= portal.x + radius) : (x += 1) {
                if (@max(@abs(x - portal.x), @abs(y - portal.y)) != radius) continue;
                if (!grid_map.isWalkableFor(x, y, profile)) continue;
                if (game_map.objectAt(x, y) != null and !canStepInto(game_map, .{ .x = x, .y = y }, moving_id)) continue;
                return .{ .x = x, .y = y };
            }
        }
    }
    return null;
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

test "healing pods restore nearby allied units" {
    var game_map = map_mod.GameMap.initDefault();
    var sim: Simulation = .{};
    var healed = false;
    for (game_map.objects[0..game_map.object_count]) |*object| {
        if (object.kind == .infantry and object.team == 0) {
            object.x = 8;
            object.y = 25;
            object.hp = 20;
            sim.resolveHealing(&game_map, 1.0);
            try std.testing.expect(object.hp > 20);
            healed = true;
            break;
        }
    }
    try std.testing.expect(healed);
}

test "portals move units to linked portal exits" {
    var grid = try path.GridMap.init(std.testing.allocator, map_mod.MapW, map_mod.MapH);
    defer grid.deinit();
    var game_map = map_mod.GameMap.initDefault();
    game_map.rebuildGrid(&grid);
    var sim: Simulation = .{};
    const before_x = game_map.objects[18].x;
    const before_y = game_map.objects[18].y;
    game_map.objects[18].x = 12;
    game_map.objects[18].y = 10;
    sim.resolvePortals(&game_map, &grid);
    try std.testing.expect(game_map.objects[18].x != before_x or game_map.objects[18].y != before_y);
    try std.testing.expect(@abs(game_map.objects[18].x - 20) <= 3);
    try std.testing.expect(@abs(game_map.objects[18].y - 21) <= 3);
}
