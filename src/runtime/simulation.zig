const std = @import("std");
const map_mod = @import("../map/map.zig");
const path = @import("../pathfinding/mod.zig");

const EngagementRange: f32 = 1.5;
const LowHealthPct: f32 = 0.45;
const GuardDamagePct: f32 = 0.05;
const RetreatDamagePct: f32 = 0.14;
const DrawSeconds: f32 = 18.0;
const ObjectiveGuardRadiusSq: f32 = 25.0;
const ObjectiveThreatRadiusSq: f32 = 81.0;
const ObjectiveGuardMin: usize = 1;
pub const MaxShotEvents = 96;
pub const SetupCoreObjectiveLimit: usize = 1;
pub const SetupMobileUnitLimit: usize = 30;
pub const SetupPortalLimit: usize = 4;
pub const SetupHealingPodLimit: usize = 4;
pub const SetupCombatStructureLimit: usize = 4;
pub const SetupObstacleLimit: usize = 12;

pub const Phase = enum {
    setup_player_one,
    setup_player_two,
    playing,
    game_over,
};

pub const Outcome = enum {
    none,
    victory,
    draw,
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

pub fn setupPlacementLimit(kind: map_mod.ObjectKind) usize {
    return switch (kind) {
        .citadel, .imperator => SetupCoreObjectiveLimit,
        .infantry, .captain, .artillery => SetupMobileUnitLimit,
        .portal => SetupPortalLimit,
        .healing_pod => SetupHealingPodLimit,
        .outpost, .defense_grid => SetupCombatStructureLimit,
        .obstacle => SetupObstacleLimit,
    };
}

pub const Simulation = struct {
    phase: Phase = .setup_player_one,
    winner: ?u8 = null,
    outcome: Outcome = .none,
    step_timer: f32 = 0,
    no_activity_timer: f32 = 0,
    battle_prepared: bool = false,
    shot_events: [MaxShotEvents]ShotEvent = [_]ShotEvent{.{}} ** MaxShotEvents,
    shot_event_count: usize = 0,

    pub fn resetSetup(self: *Simulation) void {
        self.phase = .setup_player_one;
        self.winner = null;
        self.outcome = .none;
        self.step_timer = 0;
        self.no_activity_timer = 0;
        self.battle_prepared = false;
        self.clearShotEvents();
    }

    pub fn startPlaying(self: *Simulation) void {
        self.phase = .playing;
        self.winner = null;
        self.outcome = .none;
        self.step_timer = 0;
        self.no_activity_timer = 0;
        self.battle_prepared = false;
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
            .citadel, .imperator => matching < SetupCoreObjectiveLimit,
            .infantry, .captain, .artillery => mobile_units < SetupMobileUnitLimit,
            .portal => matching < SetupPortalLimit,
            .healing_pod => matching < SetupHealingPodLimit,
            .outpost, .defense_grid => static_structures < SetupCombatStructureLimit,
            .obstacle => matching < SetupObstacleLimit,
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
        if (!self.battle_prepared) {
            game_map.refreshBattleStats();
            self.battle_prepared = true;
        }
        self.step_timer += dt;
        self.decayDamageMemory(game_map, dt);
        self.resolveCombat(game_map, dt);
        self.resolveHealing(game_map, dt);
        if (self.checkGameOver(game_map)) return;
        var moved = false;
        if (self.step_timer >= 0.24) {
            self.step_timer = 0;
            moved = self.moveUnits(game_map, grid_map, pathfinder);
            self.resolvePortals(game_map, grid_map);
        }
        if (self.shot_event_count == 0 and !moved) {
            self.no_activity_timer += dt;
        } else {
            self.no_activity_timer = 0;
        }
        if (self.no_activity_timer >= DrawSeconds) {
            self.phase = .game_over;
            self.outcome = .draw;
            self.winner = null;
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
                game_map.objects[j].recent_damage += damage;
                if (isMobileUnit(game_map.objects[j].kind) and game_map.objects[j].recent_damage >= game_map.objects[j].max_hp * RetreatDamagePct) {
                    game_map.objects[j].retreat_steps = 5;
                }
                game_map.objects[j].hp = @max(0, game_map.objects[j].hp - damage);
                if (game_map.objects[j].hp <= 0) {
                    game_map.objects[j].active = false;
                    game_map.version += 1;
                }
            }
        }
    }

    fn decayDamageMemory(self: *Simulation, game_map: *map_mod.GameMap, dt: f32) void {
        _ = self;
        for (game_map.objects[0..game_map.object_count]) |*object| {
            const decay = @max(8.0, object.max_hp * 0.18) * dt;
            object.recent_damage = @max(0, object.recent_damage - decay);
            if (!object.active) {
                object.retreat_steps = 0;
                object.idle_steps = 0;
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

    fn moveUnits(self: *Simulation, game_map: *map_mod.GameMap, grid_map: *path.GridMap, pathfinder: *path.HierarchicalPathfinder) bool {
        _ = self;
        const profile = path.MovementProfile{ .allow_diagonal_movement = true };
        game_map.rebuildGrid(grid_map);
        var moved_any = false;
        var i: usize = 0;
        while (i < game_map.object_count) : (i += 1) {
            var object = &game_map.objects[i];
            if (!object.active) continue;
            switch (object.kind) {
                .infantry, .captain, .artillery, .imperator => {},
                else => continue,
            }
            const start = path.TileCoord{ .x = object.x, .y = object.y };
            if (object.retreat_steps > 0) {
                if (retreatStep(game_map, grid_map, object.*, profile)) |next| {
                    moveObjectTo(game_map, object, next);
                    moved_any = true;
                } else {
                    object.idle_steps = @min(object.idle_steps + 1, 20);
                }
                object.retreat_steps -= 1;
                continue;
            }
            if (hasAdjacentEnemyContact(game_map, object.*)) continue;
            const goal = chooseUnitGoal(game_map, grid_map, object.*, profile) orelse continue;
            const field = pathfinder.getFlowField(grid_map, goal, 0, profile) catch {
                var route = pathfinder.findPath(grid_map, start, goal, profile) catch continue;
                defer route.deinit();
                if (route.tiles.len >= 2 and canAdvanceInto(game_map, route.tiles[1], object.*)) {
                    moveObjectTo(game_map, object, route.tiles[1]);
                    moved_any = true;
                } else {
                    object.idle_steps = @min(object.idle_steps + 1, 20);
                }
                continue;
            };
            const direction = field.directionAt(grid_map, start);
            const delta = direction.delta();
            const next = path.TileCoord{ .x = object.x + delta.x, .y = object.y + delta.y };
            if (direction != .none and grid_map.isWalkableFor(next.x, next.y, profile) and canAdvanceInto(game_map, next, object.*)) {
                moveObjectTo(game_map, object, next);
                moved_any = true;
            } else if (object.idle_steps >= 3) {
                if (bestOpenStepToward(game_map, grid_map, object.*, goal, profile)) |alternate| {
                    moveObjectTo(game_map, object, alternate);
                    moved_any = true;
                } else {
                    object.idle_steps = @min(object.idle_steps + 1, 20);
                }
            } else {
                object.idle_steps = @min(object.idle_steps + 1, 20);
            }
        }
        return moved_any;
    }

    fn resolveHealing(self: *Simulation, game_map: *map_mod.GameMap, dt: f32) void {
        _ = self;
        for (game_map.objects[0..game_map.object_count]) |healer| {
            if (!healer.active or (healer.kind != .healing_pod and healer.kind != .citadel)) continue;
            const stats = map_mod.defaultStats(healer.kind);
            const heal_per_second = -stats.damage_per_second;
            if (heal_per_second <= 0) continue;
            const range_sq = stats.range * stats.range;
            for (game_map.objects[0..game_map.object_count]) |*target| {
                if (!target.active or target.team != healer.team) continue;
                if (target.id == healer.id and healer.kind != .citadel) continue;
                if (target.hp >= target.max_hp) continue;
                const dx: f32 = @floatFromInt(healer.x - target.x);
                const dy: f32 = @floatFromInt(healer.y - target.y);
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
        const p0_lost = teamLostVitalObjective(game_map, 0);
        const p1_lost = teamLostVitalObjective(game_map, 1);
        if (p0_lost and p1_lost) {
            self.phase = .game_over;
            self.winner = null;
            self.outcome = .draw;
            return true;
        }
        if (p0_lost) {
            self.phase = .game_over;
            self.winner = 1;
            self.outcome = .victory;
            return true;
        }
        if (p1_lost) {
            self.phase = .game_over;
            self.winner = 0;
            self.outcome = .victory;
            return true;
        }
        return false;
    }
};

fn teamLostVitalObjective(game_map: *map_mod.GameMap, team: u8) bool {
    return game_map.findObject(.imperator, team) == null or game_map.findObject(.citadel, team) == null;
}

fn chooseUnitGoal(
    game_map: *map_mod.GameMap,
    grid_map: *const path.GridMap,
    object: map_mod.MapObject,
    profile: path.MovementProfile,
) ?path.TileCoord {
    if (objectiveGuardGoal(game_map, grid_map, object, profile)) |goal| return goal;
    if (threatenedObjective(game_map, grid_map, object.team, .imperator, profile)) |goal| return goal;
    if (threatenedObjective(game_map, grid_map, object.team, .citadel, profile)) |goal| return goal;
    if (object.hp <= object.max_hp * LowHealthPct) {
        if (nearestFriendlyHealerGoal(game_map, grid_map, object, profile)) |goal| return goal;
    }
    const enemy_team: u8 = if (object.team == 0) 1 else 0;
    if (game_map.findObject(.imperator, enemy_team)) |target| {
        if (approachTile(grid_map, target.*, profile)) |goal| return goal;
    }
    if (game_map.findObject(.citadel, enemy_team)) |target| {
        if (approachTile(grid_map, target.*, profile)) |goal| return goal;
    }
    return null;
}

fn objectiveGuardGoal(
    game_map: *map_mod.GameMap,
    grid_map: *const path.GridMap,
    object: map_mod.MapObject,
    profile: path.MovementProfile,
) ?path.TileCoord {
    if (!isMobileUnit(object.kind) or object.kind == .imperator) return null;
    if (currentGuardGoal(game_map, object, .imperator)) |goal| return goal;
    if (currentGuardGoal(game_map, object, .citadel)) |goal| return goal;
    if (unguardedObjectiveGoal(game_map, grid_map, object, .imperator, profile)) |goal| return goal;
    if (unguardedObjectiveGoal(game_map, grid_map, object, .citadel, profile)) |goal| return goal;
    return null;
}

fn currentGuardGoal(game_map: *map_mod.GameMap, object: map_mod.MapObject, objective_kind: map_mod.ObjectKind) ?path.TileCoord {
    const objective = game_map.findObject(objective_kind, object.team) orelse return null;
    if (!objectiveNeedsGuard(game_map, objective.*)) return null;
    if (tileDistanceSq(object, objective.*) > ObjectiveGuardRadiusSq) return null;
    if (countObjectiveGuards(game_map, objective.*, object.id) >= ObjectiveGuardMin) return null;
    return .{ .x = object.x, .y = object.y };
}

fn unguardedObjectiveGoal(
    game_map: *map_mod.GameMap,
    grid_map: *const path.GridMap,
    object: map_mod.MapObject,
    objective_kind: map_mod.ObjectKind,
    profile: path.MovementProfile,
) ?path.TileCoord {
    const objective = game_map.findObject(objective_kind, object.team) orelse return null;
    if (!objectiveNeedsGuard(game_map, objective.*)) return null;
    if (countObjectiveGuards(game_map, objective.*, object.id) >= ObjectiveGuardMin) return null;
    if (tileDistanceSq(object, objective.*) <= ObjectiveGuardRadiusSq) {
        return .{ .x = object.x, .y = object.y };
    }
    return approachTile(grid_map, objective.*, profile);
}

fn objectiveNeedsGuard(game_map: *map_mod.GameMap, objective: map_mod.MapObject) bool {
    if (objective.recent_damage >= objective.max_hp * GuardDamagePct) return true;
    if (objective.hp <= objective.max_hp * 0.82) return true;
    for (game_map.objects[0..game_map.object_count]) |object| {
        if (!object.active or object.team == objective.team or !isTargetable(object.kind)) continue;
        if (tileDistanceSq(object, objective) <= ObjectiveThreatRadiusSq) return true;
    }
    return false;
}

fn countObjectiveGuards(game_map: *map_mod.GameMap, objective: map_mod.MapObject, moving_id: u32) usize {
    var count: usize = 0;
    for (game_map.objects[0..game_map.object_count]) |object| {
        if (!object.active or object.id == moving_id) continue;
        if (object.team != objective.team or object.kind == .imperator or !isMobileUnit(object.kind)) continue;
        if (tileDistanceSq(object, objective) <= ObjectiveGuardRadiusSq) count += 1;
    }
    return count;
}

fn nearestFriendlyHealerGoal(
    game_map: *map_mod.GameMap,
    grid_map: *const path.GridMap,
    object: map_mod.MapObject,
    profile: path.MovementProfile,
) ?path.TileCoord {
    var best_goal: ?path.TileCoord = null;
    var best_dist: f32 = 999999;
    for (game_map.objects[0..game_map.object_count]) |healer| {
        if (!healer.active or healer.team != object.team) continue;
        if (healer.kind != .healing_pod and healer.kind != .citadel) continue;
        const goal = approachTile(grid_map, healer, profile) orelse continue;
        const dx: f32 = @floatFromInt(object.x - goal.x);
        const dy: f32 = @floatFromInt(object.y - goal.y);
        const dist = dx * dx + dy * dy;
        if (dist < best_dist) {
            best_dist = dist;
            best_goal = goal;
        }
    }
    return best_goal;
}

fn threatenedObjective(
    game_map: *map_mod.GameMap,
    grid_map: *const path.GridMap,
    team: u8,
    kind: map_mod.ObjectKind,
    profile: path.MovementProfile,
) ?path.TileCoord {
    const objective = game_map.findObject(kind, team) orelse return null;
    if (objective.recent_damage < objective.max_hp * GuardDamagePct and objective.hp > objective.max_hp * 0.7) return null;
    const threat = nearestEnemyTo(game_map, objective.*) orelse return approachTile(grid_map, objective.*, profile);
    return approachTile(grid_map, threat.*, profile) orelse approachTile(grid_map, objective.*, profile);
}

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

fn moveObjectTo(game_map: *map_mod.GameMap, object: *map_mod.MapObject, coord: path.TileCoord) void {
    object.x = coord.x;
    object.y = coord.y;
    object.idle_steps = 0;
    game_map.version += 1;
}

fn bestOpenStepToward(
    game_map: *map_mod.GameMap,
    grid_map: *path.GridMap,
    object: map_mod.MapObject,
    goal: path.TileCoord,
    profile: path.MovementProfile,
) ?path.TileCoord {
    var best: ?path.TileCoord = null;
    var best_dist: f32 = 999999;
    var dy: i32 = -1;
    while (dy <= 1) : (dy += 1) {
        var dx: i32 = -1;
        while (dx <= 1) : (dx += 1) {
            if (dx == 0 and dy == 0) continue;
            const next = path.TileCoord{ .x = object.x + dx, .y = object.y + dy };
            if (!grid_map.isWalkableFor(next.x, next.y, profile)) continue;
            if (!canAdvanceInto(game_map, next, object)) continue;
            const gx: f32 = @floatFromInt(goal.x - next.x);
            const gy: f32 = @floatFromInt(goal.y - next.y);
            const dist = gx * gx + gy * gy;
            if (dist < best_dist) {
                best_dist = dist;
                best = next;
            }
        }
    }
    return best;
}

fn retreatStep(
    game_map: *map_mod.GameMap,
    grid_map: *path.GridMap,
    object: map_mod.MapObject,
    profile: path.MovementProfile,
) ?path.TileCoord {
    var best: ?path.TileCoord = null;
    var best_score: f32 = -999999;
    var dy: i32 = -1;
    while (dy <= 1) : (dy += 1) {
        var dx: i32 = -1;
        while (dx <= 1) : (dx += 1) {
            if (dx == 0 and dy == 0) continue;
            const next = path.TileCoord{ .x = object.x + dx, .y = object.y + dy };
            if (!grid_map.isWalkableFor(next.x, next.y, profile)) continue;
            if (!canAdvanceInto(game_map, next, object)) continue;
            const score = nearestEnemyDistanceSq(game_map, object.team, next);
            if (score > best_score) {
                best_score = score;
                best = next;
            }
        }
    }
    return best;
}

fn nearestEnemyDistanceSq(game_map: *map_mod.GameMap, team: u8, coord: path.TileCoord) f32 {
    var best: f32 = 999999;
    for (game_map.objects[0..game_map.object_count]) |target| {
        if (!target.active or target.team == team or !isTargetable(target.kind)) continue;
        const dx: f32 = @floatFromInt(coord.x - target.x);
        const dy: f32 = @floatFromInt(coord.y - target.y);
        best = @min(best, dx * dx + dy * dy);
    }
    return best;
}

fn nearestEnemyTo(game_map: *map_mod.GameMap, object: map_mod.MapObject) ?*map_mod.MapObject {
    var best: ?*map_mod.MapObject = null;
    var best_dist: f32 = 999999;
    for (game_map.objects[0..game_map.object_count]) |*target| {
        if (!target.active or target.team == object.team or !isTargetable(target.kind)) continue;
        const dist = tileDistanceSq(object, target.*);
        if (dist < best_dist) {
            best_dist = dist;
            best = target;
        }
    }
    return best;
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
        .imperator => 0,
        .citadel => 1,
        .infantry, .captain, .artillery, .outpost, .defense_grid => 2,
        .healing_pod, .portal => 3,
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

test "combat prioritizes imperator before citadel" {
    var game_map: map_mod.GameMap = .{};
    _ = game_map.addObject(.artillery, 4, 5, 0, 0, 0);
    const citadel_id = game_map.addObject(.citadel, 5, 5, 1, 1, 0).?;
    const imperator_id = game_map.addObject(.imperator, 7, 5, 1, 1, 0).?;

    var sim: Simulation = .{};
    sim.resolveCombat(&game_map, 0.25);

    const citadel = objectById(&game_map, citadel_id).?;
    const imperator = objectById(&game_map, imperator_id).?;
    try std.testing.expectEqual(citadel.max_hp, citadel.hp);
    try std.testing.expect(imperator.hp < imperator.max_hp);
}

test "destroying either vital objective ends the game" {
    var game_map: map_mod.GameMap = .{};
    const p0_citadel_id = game_map.addObject(.citadel, 1, 5, 0, 0, 0).?;
    _ = game_map.addObject(.imperator, 1, 7, 0, 0, 0);
    _ = game_map.addObject(.citadel, 12, 5, 1, 1, 0);
    _ = game_map.addObject(.imperator, 12, 7, 1, 1, 0);
    objectById(&game_map, p0_citadel_id).?.active = false;

    var sim: Simulation = .{ .phase = .playing };
    try std.testing.expect(sim.checkGameOver(&game_map));
    try std.testing.expectEqual(Phase.game_over, sim.phase);
    try std.testing.expectEqual(Outcome.victory, sim.outcome);
    try std.testing.expectEqual(@as(?u8, 1), sim.winner);
}

test "simultaneous vital objective loss is a draw" {
    var game_map: map_mod.GameMap = .{};
    const p0_citadel_id = game_map.addObject(.citadel, 1, 5, 0, 0, 0).?;
    _ = game_map.addObject(.imperator, 1, 7, 0, 0, 0);
    _ = game_map.addObject(.citadel, 12, 5, 1, 1, 0);
    const p1_imperator_id = game_map.addObject(.imperator, 12, 7, 1, 1, 0).?;
    objectById(&game_map, p0_citadel_id).?.active = false;
    objectById(&game_map, p1_imperator_id).?.active = false;

    var sim: Simulation = .{ .phase = .playing };
    try std.testing.expect(sim.checkGameOver(&game_map));
    try std.testing.expectEqual(Phase.game_over, sim.phase);
    try std.testing.expectEqual(Outcome.draw, sim.outcome);
    try std.testing.expect(sim.winner == null);
}

test "setup mobile unit allotment is symmetric" {
    var game_map: map_mod.GameMap = .{};
    var sim: Simulation = .{ .phase = .setup_player_one };
    var i: usize = 0;
    while (i < SetupMobileUnitLimit) : (i += 1) {
        _ = game_map.addObject(.infantry, @as(i32, @intCast(i)) + 1, 1, 0, 0, 0);
    }
    try std.testing.expect(!sim.canPlaceObject(&game_map, .captain, 0));
    try std.testing.expect(!sim.canPlaceObject(&game_map, .infantry, 1));

    sim.phase = .setup_player_two;
    try std.testing.expect(sim.canPlaceObject(&game_map, .captain, 1));
    i = 0;
    while (i < SetupMobileUnitLimit) : (i += 1) {
        _ = game_map.addObject(.artillery, @as(i32, @intCast(i)) + 1, 3, 1, 1, 1);
    }
    try std.testing.expect(!sim.canPlaceObject(&game_map, .infantry, 1));
}

test "low health units move toward friendly healing" {
    var grid = try path.GridMap.init(std.testing.allocator, map_mod.MapW, map_mod.MapH);
    defer grid.deinit();
    var game_map: map_mod.GameMap = .{};
    _ = game_map.addObject(.citadel, 1, 5, 0, 0, 0);
    _ = game_map.addObject(.imperator, 1, 7, 0, 0, 0);
    _ = game_map.addObject(.healing_pod, 3, 5, 0, 0, 0);
    _ = game_map.addObject(.citadel, 12, 5, 1, 1, 0);
    _ = game_map.addObject(.imperator, 12, 7, 1, 1, 0);
    const unit_id = game_map.addObject(.infantry, 6, 5, 0, 0, 0).?;
    objectById(&game_map, unit_id).?.hp = 20;
    game_map.rebuildGrid(&grid);
    var pathfinder = path.HierarchicalPathfinder.init(std.testing.allocator, 8);
    defer pathfinder.deinit();
    try pathfinder.build(&grid, .{ .allow_diagonal_movement = true });

    var sim: Simulation = .{};
    const before = objectById(&game_map, unit_id).?;
    const before_dist = @abs(before.x - 3) + @abs(before.y - 5);
    _ = sim.moveUnits(&game_map, &grid, &pathfinder);
    const after = objectById(&game_map, unit_id).?;
    const after_dist = @abs(after.x - 3) + @abs(after.y - 5);
    try std.testing.expect(after_dist < before_dist);
}

test "guards leave quiet citadels to join the attack" {
    var grid = try path.GridMap.init(std.testing.allocator, map_mod.MapW, map_mod.MapH);
    defer grid.deinit();
    var game_map: map_mod.GameMap = .{};
    _ = game_map.addObject(.citadel, 4, 5, 0, 0, 0);
    _ = game_map.addObject(.imperator, 12, 5, 0, 0, 0);
    _ = game_map.addObject(.citadel, 20, 5, 1, 1, 0);
    _ = game_map.addObject(.imperator, 22, 5, 1, 1, 0);
    const guard_id = game_map.addObject(.infantry, 5, 5, 0, 0, 0).?;
    game_map.rebuildGrid(&grid);

    const guard = objectById(&game_map, guard_id).?.*;
    const goal = chooseUnitGoal(&game_map, &grid, guard, .{ .allow_diagonal_movement = true }) orelse return error.NoGoal;
    try std.testing.expect(goal.x != guard.x or goal.y != guard.y);
    try std.testing.expect(@abs(goal.x - 22) <= 1);
    try std.testing.expect(@abs(goal.y - 5) <= 1);
}

test "guards stay only when enemies threaten the citadel" {
    var grid = try path.GridMap.init(std.testing.allocator, map_mod.MapW, map_mod.MapH);
    defer grid.deinit();
    var game_map: map_mod.GameMap = .{};
    _ = game_map.addObject(.citadel, 4, 5, 0, 0, 0);
    _ = game_map.addObject(.imperator, 12, 5, 0, 0, 0);
    _ = game_map.addObject(.citadel, 20, 5, 1, 1, 0);
    _ = game_map.addObject(.imperator, 22, 5, 1, 1, 0);
    const guard_id = game_map.addObject(.infantry, 5, 5, 0, 0, 0).?;
    _ = game_map.addObject(.infantry, 8, 5, 1, 1, 1);
    game_map.rebuildGrid(&grid);

    const guard = objectById(&game_map, guard_id).?.*;
    const goal = chooseUnitGoal(&game_map, &grid, guard, .{ .allow_diagonal_movement = true }) orelse return error.NoGoal;
    try std.testing.expectEqual(guard.x, goal.x);
    try std.testing.expectEqual(guard.y, goal.y);
}

test "damaged citadels call free units toward nearby threats" {
    var grid = try path.GridMap.init(std.testing.allocator, map_mod.MapW, map_mod.MapH);
    defer grid.deinit();
    var game_map: map_mod.GameMap = .{};
    const citadel_id = game_map.addObject(.citadel, 4, 5, 0, 0, 0).?;
    _ = game_map.addObject(.imperator, 12, 5, 0, 0, 0);
    _ = game_map.addObject(.citadel, 20, 5, 1, 1, 0);
    _ = game_map.addObject(.imperator, 22, 5, 1, 1, 0);
    _ = game_map.addObject(.infantry, 5, 5, 0, 0, 0);
    _ = game_map.addObject(.captain, 11, 5, 0, 0, 0);
    const defender_id = game_map.addObject(.artillery, 9, 8, 0, 0, 0).?;
    _ = game_map.addObject(.infantry, 6, 5, 1, 1, 1);
    objectById(&game_map, citadel_id).?.recent_damage = objectById(&game_map, citadel_id).?.max_hp * 0.1;
    game_map.rebuildGrid(&grid);

    const defender = objectById(&game_map, defender_id).?.*;
    const goal = chooseUnitGoal(&game_map, &grid, defender, .{ .allow_diagonal_movement = true }) orelse return error.NoGoal;
    try std.testing.expect(@abs(goal.x - 6) <= 1);
    try std.testing.expect(@abs(goal.y - 5) <= 1);
}

test "quiet battle with both imperators alive becomes a draw" {
    var grid = try path.GridMap.init(std.testing.allocator, map_mod.MapW, map_mod.MapH);
    defer grid.deinit();
    var game_map: map_mod.GameMap = .{};
    _ = game_map.addObject(.imperator, 1, 1, 0, 0, 0);
    _ = game_map.addObject(.imperator, 30, 30, 1, 1, 0);
    game_map.rebuildGrid(&grid);
    var pathfinder = path.HierarchicalPathfinder.init(std.testing.allocator, 8);
    defer pathfinder.deinit();
    try pathfinder.build(&grid, .{ .allow_diagonal_movement = true });

    var sim: Simulation = .{};
    sim.startPlaying();
    sim.no_activity_timer = DrawSeconds - 0.1;
    sim.update(&game_map, &grid, &pathfinder, 0.11);

    try std.testing.expectEqual(Phase.game_over, sim.phase);
    try std.testing.expectEqual(Outcome.draw, sim.outcome);
    try std.testing.expect(sim.winner == null);
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

test "citadels regenerate themselves" {
    var game_map: map_mod.GameMap = .{};
    const citadel_id = game_map.addObject(.citadel, 5, 5, 0, 0, 0).?;
    const citadel = objectById(&game_map, citadel_id).?;
    citadel.hp = citadel.max_hp - 100;
    const before = citadel.hp;

    var sim: Simulation = .{};
    sim.resolveHealing(&game_map, 1.0);

    const healed = objectById(&game_map, citadel_id).?;
    try std.testing.expect(healed.hp > before);
    try std.testing.expect(healed.hp <= healed.max_hp);
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

test "same-team linked portals move mobile units" {
    var grid = try path.GridMap.init(std.testing.allocator, map_mod.MapW, map_mod.MapH);
    defer grid.deinit();
    var game_map: map_mod.GameMap = .{};
    _ = game_map.addObject(.portal, 3, 3, 0, 0, 0);
    _ = game_map.addObject(.portal, 12, 12, 0, 0, 0);
    const unit_id = game_map.addObject(.captain, 3, 3, 0, 0, 0).?;
    game_map.rebuildGrid(&grid);

    var sim: Simulation = .{};
    sim.resolvePortals(&game_map, &grid);

    const unit = objectById(&game_map, unit_id).?;
    try std.testing.expect(unit.x != 3 or unit.y != 3);
    try std.testing.expect(@abs(unit.x - 12) <= 3);
    try std.testing.expect(@abs(unit.y - 12) <= 3);
}

fn objectById(game_map: *map_mod.GameMap, id: u32) ?*map_mod.MapObject {
    for (game_map.objects[0..game_map.object_count]) |*object| {
        if (object.id == id) return object;
    }
    return null;
}
