const std = @import("std");
const grid = @import("grid_map.zig");

pub const Sector = struct {
    id: usize,
    x: i32,
    y: i32,
    width: i32,
    height: i32,

    pub fn contains(self: Sector, coord: grid.TileCoord) bool {
        return coord.x >= self.x and coord.y >= self.y and coord.x < self.x + self.width and coord.y < self.y + self.height;
    }

    pub fn center(self: Sector) grid.TileCoord {
        return .{
            .x = self.x + @divTrunc(self.width, 2),
            .y = self.y + @divTrunc(self.height, 2),
        };
    }
};

pub fn buildSectors(allocator: std.mem.Allocator, map: *const grid.GridMap, sector_size: usize) ![]Sector {
    if (sector_size == 0) return error.InvalidSectorSize;
    var sectors: std.ArrayList(Sector) = .empty;
    errdefer sectors.deinit(allocator);

    var y: usize = 0;
    var id: usize = 0;
    while (y < map.height) : (y += sector_size) {
        var x: usize = 0;
        while (x < map.width) : (x += sector_size) {
            try sectors.append(allocator, .{
                .id = id,
                .x = @intCast(x),
                .y = @intCast(y),
                .width = @intCast(@min(sector_size, map.width - x)),
                .height = @intCast(@min(sector_size, map.height - y)),
            });
            id += 1;
        }
    }
    return sectors.toOwnedSlice(allocator);
}

pub fn columns(map_width: usize, sector_size: usize) usize {
    return (map_width + sector_size - 1) / sector_size;
}

pub fn sectorIdForCoord(map: *const grid.GridMap, sector_size: usize, coord: grid.TileCoord) ?usize {
    if (!map.isInside(coord.x, coord.y) or sector_size == 0) return null;
    const col_count = columns(map.width, sector_size);
    const sx = @as(usize, @intCast(coord.x)) / sector_size;
    const sy = @as(usize, @intCast(coord.y)) / sector_size;
    return sy * col_count + sx;
}

test "sector splitting covers partial edges" {
    var g = try grid.GridMap.init(std.testing.allocator, 10, 9);
    defer g.deinit();
    const sectors = try buildSectors(std.testing.allocator, &g, 4);
    defer std.testing.allocator.free(sectors);

    try std.testing.expectEqual(@as(usize, 9), sectors.len);
    try std.testing.expectEqual(@as(i32, 2), sectors[2].width);
    try std.testing.expectEqual(@as(i32, 1), sectors[8].height);
    try std.testing.expectEqual(@as(usize, 4), sectorIdForCoord(&g, 4, .{ .x = 5, .y = 5 }).?);
}

