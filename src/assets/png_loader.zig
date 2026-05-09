const std = @import("std");

const c = @cImport({
    @cInclude("stb_image.h");
});

pub const LoadedImage = struct {
    width: i32,
    height: i32,
    pixels: []u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: LoadedImage) void {
        self.allocator.free(self.pixels);
    }
};

pub fn loadRgba(allocator: std.mem.Allocator, path: []const u8) !LoadedImage {
    const zpath = try allocator.dupeZ(u8, path);
    defer allocator.free(zpath);

    c.stbi_set_flip_vertically_on_load(1);

    var width: c_int = 0;
    var height: c_int = 0;
    var channels: c_int = 0;
    const raw = c.stbi_load(zpath.ptr, &width, &height, &channels, 4) orelse return error.ImageDecodeFailed;
    defer c.stbi_image_free(raw);

    if (width <= 0 or height <= 0) return error.InvalidImageSize;

    const pixel_count: usize = @intCast(width * height * 4);
    const pixels = try allocator.alloc(u8, pixel_count);
    @memcpy(pixels, @as([*]u8, @ptrCast(raw))[0..pixel_count]);
    return .{
        .width = width,
        .height = height,
        .pixels = pixels,
        .allocator = allocator,
    };
}

