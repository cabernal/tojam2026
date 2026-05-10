const map_mod = @import("../map/map.zig");

pub fn terrainColor(cell: map_mod.TerrainCell) [4]f32 {
    if (map_mod.isVoidTerrain(cell)) return .{ 0.03, 0.08, 0.12, 0.10 };
    if (!cell.walkable) return .{ 0.25, 0.22, 0.20, 1.0 };
    return switch (cell.terrain_id % 5) {
        0 => .{ 0.55, 0.48, 0.35, 1.0 },
        1 => .{ 0.62, 0.54, 0.39, 1.0 },
        2 => .{ 0.42, 0.38, 0.32, 1.0 },
        3 => .{ 0.20, 0.40, 0.46, 1.0 },
        else => .{ 0.50, 0.44, 0.34, 1.0 },
    };
}
