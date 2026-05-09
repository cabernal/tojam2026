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

    pub fn togglePlay(self: *Simulation) void {
        self.phase = if (self.phase == .playing) .setup_player_one else .playing;
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
            const goal = path.TileCoord{ .x = target.x, .y = target.y };
            var route = pathfinder.findPath(grid_map, start, goal, profile) catch continue;
            defer route.deinit();
            if (route.tiles.len >= 2) {
                object.x = route.tiles[1].x;
                object.y = route.tiles[1].y;
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

