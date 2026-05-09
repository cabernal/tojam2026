const schema = @import("../map/schema.zig");

pub const Tool = enum {
    terrain,
    object,
    erase,
    select,
};

pub fn toolName(tool: Tool) []const u8 {
    return switch (tool) {
        .terrain => "Terrain",
        .object => "Object",
        .erase => "Erase",
        .select => "Select",
    };
}

pub fn objectKindName(kind: schema.ObjectKind) []const u8 {
    return switch (kind) {
        .citadel => "Citadel",
        .imperator => "Imperator",
        .infantry => "Infantry",
        .captain => "Captain",
        .artillery => "Artillery",
        .portal => "Portal",
        .healing_pod => "Healing Pod",
        .obstacle => "Obstacle",
        .outpost => "Outpost",
        .defense_grid => "Defense Grid",
    };
}

pub const ObjectPalette = [_]schema.ObjectKind{
    .citadel,
    .imperator,
    .infantry,
    .captain,
    .artillery,
    .portal,
    .healing_pod,
    .obstacle,
    .outpost,
    .defense_grid,
};

