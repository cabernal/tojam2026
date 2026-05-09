const std = @import("std");
const map_mod = @import("../map/map.zig");

pub fn distance(a: map_mod.MapObject, b: map_mod.MapObject) f32 {
    const dx: f32 = @floatFromInt(a.x - b.x);
    const dy: f32 = @floatFromInt(a.y - b.y);
    return @sqrt(dx * dx + dy * dy);
}

pub fn applyDamage(target: *map_mod.MapObject, amount: f32) void {
    target.hp = @max(0, target.hp - amount);
    if (target.hp <= 0) target.active = false;
}

