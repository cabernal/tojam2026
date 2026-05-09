pub const SchemaVersion: u32 = 1;
pub const MapW: usize = 32;
pub const MapH: usize = 32;
pub const MaxObjects: usize = 192;
pub const DefaultMapPath = "assets/maps/default/map.json";

pub const ObjectKind = enum {
    citadel,
    imperator,
    infantry,
    captain,
    artillery,
    portal,
    healing_pod,
    obstacle,
    outpost,
    defense_grid,

    pub fn jsonName(self: ObjectKind) []const u8 {
        return switch (self) {
            .citadel => "citadel",
            .imperator => "imperator",
            .infantry => "infantry",
            .captain => "captain",
            .artillery => "artillery",
            .portal => "portal",
            .healing_pod => "healing_pod",
            .obstacle => "obstacle",
            .outpost => "outpost",
            .defense_grid => "defense_grid",
        };
    }

    pub fn fromJsonName(name: []const u8) ?ObjectKind {
        inline for (@typeInfo(ObjectKind).@"enum".fields) |field| {
            const value: ObjectKind = @enumFromInt(field.value);
            if (std.mem.eql(u8, name, value.jsonName())) return value;
        }
        return null;
    }
};

const std = @import("std");

