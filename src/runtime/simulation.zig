const std = @import("std");
const map_mod = @import("../map/map.zig");
const path = @import("../pathfinding/mod.zig");

const EngagementRange: f32 = 1.5;
pub const MaxShotEvents = 96;

pub const Phase = enum {
    setup_player_one,
    setup_player_two,
    playing,
    game_over,
};

pub const ShotEvent = struct {
    attacker_id: u32 = 0,
    target_id: u32 = 0,
    attacker_team: u8 = 0,
    attacker_kind: map_mod.ObjectKind = .infantry,
    target_kind: map_mod.ObjectKind = .infantry,
    start_x: f32 = 0,
    start_y: f32 = 0,
    end_x: f32 = 0,
    end_y: f32 = 0,
    damage: f32 = 0,
};

pub const Simulation = struct {
    phase: Phase = .setup_player_one,
    winner: ?u8 = null,
    step_timer: f32 = 0,
    shot_events: [MaxShotEvents]ShotEvent = [_]ShotEvent{.{}} ** MaxShotEvents,
    shot_event_count: usize = 0,

    pub fn resetSetup(self: *Simulation) void {
        self.phase = .setup_player_one;
        self.winner = null;
        self.step_timer = 0;
        self.clearShotEvents();
    }

    pub fn startPlaying(self: *Simulation) void {
        self.phase = .playing;
        self.winner = null;
        self.step_timer = 0;
        self.clearShotEvents();
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
        self.clearShotEvents();
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
        var i: usize = 0;
        while (i < game_map.object_count) : (i += 1) {
            if (!game_map.objects[i].active) continue;
            const attacker = game_map.objects[i];
            const stats = map_mod.defaultStats(attacker.kind);
            if (stats.damage_per_second <= 0) continue;
            const attack_range = effectiveAttackRange(attacker.kind, stats.range);
            const attack_range_sq = attack_range * attack_range;

            var target_idx: ?usize = null;
            var best_priority: u8 = 255;
            var best_dist_sq: f32 = 999999;
            for (game_map.objects[0..game_map.object_count], 0..) |target, j| {
                if (!target.active or target.team == attacker.team) continue;
                if (!isTargetable(target.kind)) continue;
                const dx: f32 = @floatFromInt(attacker.x - target.x);
                const dy: f32 = @floatFromInt(attacker.y - target.y);
                const dist_sq = dx * dx + dy * dy;
                const priority = targetPriority(target.kind);
                if (dist_sq <= attack_range_sq and (priority < best_priority or (priority == best_priority and dist_sq < best_dist_sq))) {
                    target_idx = j;
                    best_priority = priority;
                    best_dist_sq = dist_sq;
                }
            }
            if (target_idx) |j| {
                const damage = stats.damage_per_second * dt;
                self.recordShot(attacker, game_map.objects[j], damage);
                game_map.objects[j].hp = @max(0, game_map.objects[j].hp - damage);
                if (game_map.objects[j].hp <= 0) {
                    game_map.objects[j].active = false;
                    game_map.version += 1;
                }
            }
        }
    }

    fn clearShotEvents(self: *Simulation) void {
        self.shot_event_count = 0;
    }

    fn recordShot(self: *Simulation, attacker: map_mod.MapObject, target: map_mod.MapObject, damage: f32) void {
        if (self.shot_event_count >= self.shot_events.len) return;
        self.shot_events[self.shot_event_count] = .{
            .attacker_id = attacker.id,
            .target_id = target.id,
            .attacker_team = attacker.team,
            .attacker_kind = attacker.kind,
            .target_kind = target.kind,
            .start_x = @as(f32, @floatFromInt(attacker.x)) + 0.5,
            .start_y = @as(f32, @floatFromInt(attacker.y)) + 0.5,
            .end_x = @as(f32, @floatFromInt(target.x)) + 0.5,
            .end_y = @as(f32, @floatFromInt(target.y)) + 0.5,
            .damage = damage,
        };
        self.shot_event_count += 1;
    }

    fn moveUnits(self: *Simulation, game_map: *map_mod.GameMap, grid_map: *path.GridMap, pathfinder: *path.HierarchicalPathfinder) void {
        _ = self;
        const profile = path.MovementProfile{ .allow_diagonal_movement = true };
        game_map.rebuildGrid(grid_map);
        var i: usize = 0;
        while (i < game_map.object_count) : (i += 1) {
            const object = &game_map.objects[i];
            if (!object.active) continue;
            switch (object.kind) {
                .infantry, .captain, .artillery, .imperator => {},
                else => continue,
            }
            const target_team: u8 = if (object.team == 0) 1 else 0;
            const start = path.TileCoord{ .x = object.x, .y = object.y };
            if (hasAdjacentEnemyContact(game_map, object.*)) continue;
            const goal = movementGoalForUnit(game_map, grid_map, object.*, target_team, profile) orelse continue;
            const field = pathfinder.getFlowField(grid_map, goal, 0, profile) catch {
                var route = pathfinder.findPath(grid_map, start, goal, profile) catch continue;
                defer route.deinit();
                if (route.tiles.len >= 2 and advanceUnitToward(game_map, grid_map, object, route.tiles[1], goal, profile)) {
                    game_map.version += 1;
                }
                continue;
            };
            const direction = field.directionAt(grid_map, start);
            const delta = direction.delta();
            const next = path.TileCoord{ .x = object.x + delta.x, .y = object.y + delta.y };
            if (direction != .none and advanceUnitToward(game_map, grid_map, object, next, goal, profile)) {
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
            const range_sq = stats.range * stats.range;
            for (game_map.objects[0..game_map.object_count]) |*target| {
                if (!target.active or target.team != pod.team or target.id == pod.id) continue;
                if (target.hp >= target.max_hp) continue;
                const dx: f32 = @floatFromInt(pod.x - target.x);
                const dy: f32 = @floatFromInt(pod.y - target.y);
                if (dx * dx + dy * dy <= range_sq) {
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
        const p0_lost = p0 == null or !p0.?.active;
        const p1_lost = p1 == null or !p1.?.active;
        if (p0_lost and p1_lost) {
            self.phase = .game_over;
            self.winner = null;
            return true;
        }
        if (p0_lost) {
            self.phase = .game_over;
            self.winner = 1;
            return true;
        }
        if (p1_lost) {
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

fn canAdvanceInto(game_map: *map_mod.GameMap, coord: path.TileCoord, moving: map_mod.MapObject) bool {
    if (game_map.objectAt(coord.x, coord.y)) |object| {
        if (object.id == moving.id or object.kind == .portal or object.kind == .healing_pod) return true;
        return false;
    }
    return true;
}

fn movementGoalForUnit(
    game_map: *map_mod.GameMap,
    grid_map: *const path.GridMap,
    unit: map_mod.MapObject,
    target_team: u8,
    profile: path.MovementProfile,
) ?path.TileCoord {
    if (unit.kind != .imperator and shouldDefendCitadel(unit)) {
        if (threatNearCitadel(game_map, unit.team)) |threat| {
            if (approachTile(grid_map, threat, profile)) |goal| return goal;
        }
    }
    if (game_map.findObject(.citadel, target_team)) |citadel| {
        if (approachTile(grid_map, citadel.*, profile)) |goal| return goal;
    }
    if (game_map.findObject(.imperator, target_team)) |imperator| {
        if (approachTile(grid_map, imperator.*, profile)) |goal| return goal;
    }
    return null;
}

fn shouldDefendCitadel(unit: map_mod.MapObject) bool {
    return (unit.id + @as(u32, unit.team)) % 3 == 0;
}

fn threatNearCitadel(game_map: *map_mod.GameMap, team: u8) ?map_mod.MapObject {
    const citadel = game_map.findObject(.citadel, team) orelse return null;
    if (citadel.hp > citadel.max_hp * 0.68) return null;
    var best: ?map_mod.MapObject = null;
    var best_dist: f32 = 999999;
    for (game_map.objects[0..game_map.object_count]) |object| {
        if (!object.active or object.team == team or !isMobileUnit(object.kind)) continue;
        const dist = tileDistanceSq(citadel.*, object);
        if (dist > 72) continue;
        if (dist < best_dist) {
            best_dist = dist;
            best = object;
        }
    }
    return best;
}

fn advanceUnitToward(
    game_map: *map_mod.GameMap,
    grid_map: *const path.GridMap,
    unit: *map_mod.MapObject,
    preferred: path.TileCoord,
    goal: path.TileCoord,
    profile: path.MovementProfile,
) bool {
    if (canStepTo(game_map, grid_map, preferred, unit.*, profile)) {
        unit.x = preferred.x;
        unit.y = preferred.y;
        return true;
    }
    const alternate = alternateStepToward(game_map, grid_map, unit.*, goal, profile) orelse return false;
    unit.x = alternate.x;
    unit.y = alternate.y;
    return true;
}

fn canStepTo(
    game_map: *map_mod.GameMap,
    grid_map: *const path.GridMap,
    coord: path.TileCoord,
    unit: map_mod.MapObject,
    profile: path.MovementProfile,
) bool {
    return grid_map.isWalkableFor(coord.x, coord.y, profile) and canAdvanceInto(game_map, coord, unit);
}

fn alternateStepToward(
    game_map: *map_mod.GameMap,
    grid_map: *const path.GridMap,
    unit: map_mod.MapObject,
    goal: path.TileCoord,
    profile: path.MovementProfile,
) ?path.TileCoord {
    const start = path.TileCoord{ .x = unit.x, .y = unit.y };
    const current_dist = coordDistanceSq(start, goal);
    var best: ?path.TileCoord = null;
    var best_score = current_dist;
    const dirs = [_]path.Direction{ .north, .south, .west, .east, .north_west, .north_east, .south_west, .south_east };
    const offset: usize = @intCast(unit.id % dirs.len);
    for (0..dirs.len) |n| {
        const dir = dirs[(n + offset) % dirs.len];
        const delta = dir.delta();
        const candidate = path.TileCoord{ .x = unit.x + delta.x, .y = unit.y + delta.y };
        if (!canStepTo(game_map, grid_map, candidate, unit, profile)) continue;
        const score = coordDistanceSq(candidate, goal);
        if (score < best_score) {
            best_score = score;
            best = candidate;
        }
    }
    return best;
}

fn coordDistanceSq(a: path.TileCoord, b: path.TileCoord) f32 {
    const dx: f32 = @floatFromInt(a.x - b.x);
    const dy: f32 = @floatFromInt(a.y - b.y);
    return dx * dx + dy * dy;
}

fn hasAdjacentEnemyContact(game_map: *map_mod.GameMap, object: map_mod.MapObject) bool {
    const engagement_range_sq = EngagementRange * EngagementRange;
    for (game_map.objects[0..game_map.object_count]) |target| {
        if (!target.active or target.team == object.team or !isMobileUnit(target.kind)) continue;
        if (tileDistanceSq(object, target) <= engagement_range_sq) return true;
    }
    return false;
}

fn effectiveAttackRange(kind: map_mod.ObjectKind, base_range: f32) f32 {
    return if (isMobileUnit(kind)) @max(base_range, EngagementRange) else base_range;
}

fn isTargetable(kind: map_mod.ObjectKind) bool {
    return switch (kind) {
        .obstacle => false,
        else => true,
    };
}

fn targetPriority(kind: map_mod.ObjectKind) u8 {
    return switch (kind) {
        .imperator, .infantry, .captain, .artillery => 0,
        .citadel, .outpost, .defense_grid => 1,
        .healing_pod, .portal => 2,
        .obstacle => 255,
    };
}

fn tileDistanceSq(a: map_mod.MapObject, b: map_mod.MapObject) f32 {
    const dx: f32 = @floatFromInt(a.x - b.x);
    const dy: f32 = @floatFromInt(a.y - b.y);
    return dx * dx + dy * dy;
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

test "adjacent enemies stop movement and trade damage" {
    var grid = try path.GridMap.init(std.testing.allocator, map_mod.MapW, map_mod.MapH);
    defer grid.deinit();
    var game_map: map_mod.GameMap = .{};
    _ = game_map.addObject(.citadel, 1, 5, 0, 0, 0);
    _ = game_map.addObject(.imperator, 1, 7, 0, 0, 0);
    _ = game_map.addObject(.citadel, 12, 5, 1, 1, 0);
    _ = game_map.addObject(.imperator, 12, 7, 1, 1, 0);
    const attacker_id = game_map.addObject(.infantry, 4, 5, 0, 0, 0).?;
    const blocker_id = game_map.addObject(.infantry, 5, 5, 1, 1, 0).?;
    game_map.rebuildGrid(&grid);
    var pathfinder = path.HierarchicalPathfinder.init(std.testing.allocator, 8);
    defer pathfinder.deinit();
    try pathfinder.build(&grid, .{ .allow_diagonal_movement = true });

    var sim: Simulation = .{};
    sim.startPlaying();
    const before = objectById(&game_map, blocker_id).?.hp;
    sim.update(&game_map, &grid, &pathfinder, 0.25);
    const attacker = objectById(&game_map, attacker_id).?;
    const blocker = objectById(&game_map, blocker_id).?;
    try std.testing.expectEqual(@as(i32, 4), attacker.x);
    try std.testing.expectEqual(@as(i32, 5), attacker.y);
    try std.testing.expect(blocker.hp < before);
}

test "combat records shot events for visual effects" {
    var game_map: map_mod.GameMap = .{};
    const attacker_id = game_map.addObject(.infantry, 4, 5, 0, 0, 0).?;
    const target_id = game_map.addObject(.infantry, 5, 5, 1, 1, 0).?;

    var sim: Simulation = .{};
    sim.resolveCombat(&game_map, 0.25);

    try std.testing.expect(sim.shot_event_count >= 1);
    const event = sim.shot_events[0];
    try std.testing.expectEqual(attacker_id, event.attacker_id);
    try std.testing.expectEqual(target_id, event.target_id);
    try std.testing.expectEqual(@as(u8, 0), event.attacker_team);
    try std.testing.expectEqual(map_mod.ObjectKind.infantry, event.attacker_kind);
    try std.testing.expectApproxEqAbs(@as(f32, 4.5), event.start_x, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 5.5), event.end_x, 0.001);
    try std.testing.expect(event.damage > 0);
}

test "combat ignores non-targetable obstacles" {
    var game_map: map_mod.GameMap = .{};
    _ = game_map.addObject(.captain, 4, 5, 0, 0, 0);
    const obstacle_id = game_map.addObject(.obstacle, 5, 5, 1, 1, 0).?;
    const infantry_id = game_map.addObject(.infantry, 6, 5, 1, 1, 0).?;

    var sim: Simulation = .{};
    sim.resolveCombat(&game_map, 0.25);

    const obstacle_target = objectById(&game_map, obstacle_id).?;
    const infantry_target = objectById(&game_map, infantry_id).?;
    try std.testing.expectEqual(obstacle_target.max_hp, obstacle_target.hp);
    try std.testing.expect(infantry_target.hp < infantry_target.max_hp);
}

test "combat priority beats nearest target distance" {
    var game_map: map_mod.GameMap = .{};
    _ = game_map.addObject(.artillery, 4, 5, 0, 0, 0);
    const support_id = game_map.addObject(.healing_pod, 5, 5, 1, 1, 0).?;
    const threat_id = game_map.addObject(.infantry, 8, 5, 1, 1, 0).?;

    var sim: Simulation = .{};
    sim.resolveCombat(&game_map, 0.25);

    const support = objectById(&game_map, support_id).?;
    const threat = objectById(&game_map, threat_id).?;
    try std.testing.expectEqual(support.max_hp, support.hp);
    try std.testing.expect(threat.hp < threat.max_hp);
}

test "units resume citadel movement after contact enemy is destroyed" {
    var grid = try path.GridMap.init(std.testing.allocator, map_mod.MapW, map_mod.MapH);
    defer grid.deinit();
    var game_map: map_mod.GameMap = .{};
    _ = game_map.addObject(.citadel, 1, 5, 0, 0, 0);
    _ = game_map.addObject(.imperator, 1, 7, 0, 0, 0);
    _ = game_map.addObject(.citadel, 12, 5, 1, 1, 0);
    _ = game_map.addObject(.imperator, 12, 7, 1, 1, 0);
    const attacker_id = game_map.addObject(.infantry, 4, 5, 0, 0, 0).?;
    const blocker_id = game_map.addObject(.infantry, 5, 5, 1, 1, 0).?;
    objectById(&game_map, blocker_id).?.hp = 1;
    game_map.rebuildGrid(&grid);
    var pathfinder = path.HierarchicalPathfinder.init(std.testing.allocator, 8);
    defer pathfinder.deinit();
    try pathfinder.build(&grid, .{ .allow_diagonal_movement = true });

    var sim: Simulation = .{};
    sim.startPlaying();
    sim.update(&game_map, &grid, &pathfinder, 0.25);
    const attacker = objectById(&game_map, attacker_id).?;
    const blocker = objectById(&game_map, blocker_id).?;
    try std.testing.expect(!blocker.active);
    try std.testing.expect(attacker.x != 4 or attacker.y != 5);
}

test "units target imperator after enemy citadel is destroyed" {
    var grid = try path.GridMap.init(std.testing.allocator, map_mod.MapW, map_mod.MapH);
    defer grid.deinit();
    var game_map: map_mod.GameMap = .{};
    _ = game_map.addObject(.citadel, 1, 5, 0, 0, 0);
    _ = game_map.addObject(.imperator, 1, 7, 0, 0, 0);
    _ = game_map.addObject(.citadel, 12, 5, 1, 1, 0);
    _ = game_map.addObject(.imperator, 12, 7, 1, 1, 0);
    const unit_id = game_map.addObject(.infantry, 4, 5, 0, 0, 0).?;
    objectById(&game_map, 3).?.active = false;
    game_map.rebuildGrid(&grid);

    const goal = movementGoalForUnit(&game_map, &grid, objectById(&game_map, unit_id).?.*, 1, .{ .allow_diagonal_movement = true }) orelse return error.NoGoal;
    try std.testing.expect(@abs(goal.x - 12) <= 1);
    try std.testing.expect(@abs(goal.y - 7) <= 1);
}

test "some units defend damaged citadels" {
    var grid = try path.GridMap.init(std.testing.allocator, map_mod.MapW, map_mod.MapH);
    defer grid.deinit();
    var game_map: map_mod.GameMap = .{};
    const citadel_id = game_map.addObject(.citadel, 5, 5, 0, 0, 0).?;
    _ = game_map.addObject(.infantry, 7, 5, 1, 1, 0);
    const defender_id = game_map.addObject(.captain, 2, 5, 0, 0, 0).?;
    const citadel = objectById(&game_map, citadel_id).?;
    citadel.hp = citadel.max_hp * 0.4;
    game_map.rebuildGrid(&grid);

    const goal = movementGoalForUnit(&game_map, &grid, objectById(&game_map, defender_id).?.*, 1, .{ .allow_diagonal_movement = true }) orelse return error.NoGoal;
    try std.testing.expect(@abs(goal.x - 7) <= 1);
    try std.testing.expect(@abs(goal.y - 5) <= 1);
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

test "simultaneous imperator loss is a stalemate" {
    var game_map = map_mod.GameMap.initDefault();
    var sim: Simulation = .{ .phase = .playing };
    game_map.findObject(.imperator, 0).?.active = false;
    game_map.findObject(.imperator, 1).?.active = false;

    try std.testing.expect(sim.checkGameOver(&game_map));
    try std.testing.expectEqual(Phase.game_over, sim.phase);
    try std.testing.expectEqual(@as(?u8, null), sim.winner);
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

fn objectById(game_map: *map_mod.GameMap, id: u32) ?*map_mod.MapObject {
    for (game_map.objects[0..game_map.object_count]) |*object| {
        if (object.id == id) return object;
    }
    return null;
}
