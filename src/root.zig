pub const assets = @import("assets/asset_loader.zig");
pub const map = @import("map/map.zig");
pub const map_io = @import("map/map_io.zig");
pub const pathfinding = @import("pathfinding/mod.zig");
pub const runtime = @import("runtime/game.zig");

test {
    _ = @import("map/map_io.zig");
    _ = @import("pathfinding/astar.zig");
    _ = @import("pathfinding/sector.zig");
    _ = @import("pathfinding/portal_graph.zig");
    _ = @import("pathfinding/flow_field.zig");
    _ = @import("pathfinding/cache.zig");
    _ = @import("pathfinding/hierarchical.zig");
}
