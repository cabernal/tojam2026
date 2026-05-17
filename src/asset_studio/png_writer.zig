const std = @import("std");

const PngSignature = [_]u8{ 0x89, 'P', 'N', 'G', '\r', '\n', 0x1a, '\n' };

pub fn writeRgbaFile(
    allocator: std.mem.Allocator,
    path: []const u8,
    width: usize,
    height: usize,
    pixels: []const u8,
    row_stride: usize,
) !void {
    const bytes = try encodeRgba(allocator, width, height, pixels, row_stride);
    defer allocator.free(bytes);

    var file = if (std.fs.path.isAbsolute(path))
        try std.fs.createFileAbsolute(path, .{ .truncate = true })
    else
        try std.fs.cwd().createFile(path, .{ .truncate = true });
    defer file.close();
    try file.writeAll(bytes);
}

pub fn encodeRgba(
    allocator: std.mem.Allocator,
    width: usize,
    height: usize,
    pixels: []const u8,
    row_stride: usize,
) ![]u8 {
    if (width == 0 or height == 0) return error.InvalidImageSize;
    if (width > std.math.maxInt(u31) or height > std.math.maxInt(u31)) return error.InvalidImageSize;
    const row_bytes = try std.math.mul(usize, width, 4);
    if (row_stride < row_bytes) return error.InvalidImageStride;
    if (pixels.len < row_stride * (height - 1) + row_bytes) return error.InvalidImageBuffer;

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    try out.appendSlice(allocator, &PngSignature);

    var ihdr: [13]u8 = undefined;
    putU32(ihdr[0..4], @intCast(width));
    putU32(ihdr[4..8], @intCast(height));
    ihdr[8] = 8;
    ihdr[9] = 6;
    ihdr[10] = 0;
    ihdr[11] = 0;
    ihdr[12] = 0;
    try appendChunk(allocator, &out, "IHDR", &ihdr);

    var raw: std.ArrayList(u8) = .empty;
    defer raw.deinit(allocator);
    try raw.ensureTotalCapacity(allocator, height * (row_bytes + 1));
    for (0..height) |y| {
        try raw.append(allocator, 0);
        const start = y * row_stride;
        try raw.appendSlice(allocator, pixels[start .. start + row_bytes]);
    }

    const compressed = try zlibStore(allocator, raw.items);
    defer allocator.free(compressed);
    try appendChunk(allocator, &out, "IDAT", compressed);
    try appendChunk(allocator, &out, "IEND", "");

    return out.toOwnedSlice(allocator);
}

fn appendChunk(allocator: std.mem.Allocator, out: *std.ArrayList(u8), kind: []const u8, data: []const u8) !void {
    std.debug.assert(kind.len == 4);
    var len_buf: [4]u8 = undefined;
    putU32(&len_buf, @intCast(data.len));
    try out.appendSlice(allocator, &len_buf);
    try out.appendSlice(allocator, kind);
    try out.appendSlice(allocator, data);

    var crc = crc32Start();
    crc = crc32Update(crc, kind);
    crc = crc32Update(crc, data);
    const final_crc = crc32Finish(crc);
    var crc_buf: [4]u8 = undefined;
    putU32(&crc_buf, final_crc);
    try out.appendSlice(allocator, &crc_buf);
}

fn zlibStore(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    try out.append(allocator, 0x78);
    try out.append(allocator, 0x01);

    var offset: usize = 0;
    while (offset < raw.len or raw.len == 0 and offset == 0) {
        const remaining = raw.len - offset;
        const chunk_len = @min(remaining, 65535);
        const is_final = offset + chunk_len >= raw.len;
        try out.append(allocator, if (is_final) 0x01 else 0x00);

        const len: u16 = @intCast(chunk_len);
        const nlen: u16 = ~len;
        try appendU16Le(allocator, &out, len);
        try appendU16Le(allocator, &out, nlen);
        try out.appendSlice(allocator, raw[offset .. offset + chunk_len]);

        offset += chunk_len;
        if (raw.len == 0) break;
    }

    var adler_buf: [4]u8 = undefined;
    putU32(&adler_buf, adler32(raw));
    try out.appendSlice(allocator, &adler_buf);
    return out.toOwnedSlice(allocator);
}

fn appendU16Le(allocator: std.mem.Allocator, out: *std.ArrayList(u8), value: u16) !void {
    try out.append(allocator, @intCast(value & 0xff));
    try out.append(allocator, @intCast(value >> 8));
}

fn putU32(buf: []u8, value: u32) void {
    std.debug.assert(buf.len >= 4);
    buf[0] = @intCast((value >> 24) & 0xff);
    buf[1] = @intCast((value >> 16) & 0xff);
    buf[2] = @intCast((value >> 8) & 0xff);
    buf[3] = @intCast(value & 0xff);
}

fn adler32(bytes: []const u8) u32 {
    const Mod = 65521;
    var a: u32 = 1;
    var b: u32 = 0;
    for (bytes) |byte| {
        a = (a + byte) % Mod;
        b = (b + a) % Mod;
    }
    return (b << 16) | a;
}

fn crc32Start() u32 {
    return 0xffffffff;
}

fn crc32Update(start: u32, bytes: []const u8) u32 {
    var crc = start;
    for (bytes) |byte| {
        crc ^= byte;
        for (0..8) |_| {
            crc = if ((crc & 1) != 0) (crc >> 1) ^ 0xedb88320 else crc >> 1;
        }
    }
    return crc;
}

fn crc32Finish(crc: u32) u32 {
    return ~crc;
}

test "encodes a small rgba png" {
    const pixels = [_]u8{
        255, 0,   0,   255,
        0,   255, 0,   255,
        0,   0,   255, 255,
        255, 255, 255, 0,
    };
    const encoded = try encodeRgba(std.testing.allocator, 2, 2, &pixels, 2 * 4);
    defer std.testing.allocator.free(encoded);

    try std.testing.expect(encoded.len > PngSignature.len + 12);
    try std.testing.expectEqualSlices(u8, &PngSignature, encoded[0..PngSignature.len]);
    try std.testing.expectEqualSlices(u8, "IHDR", encoded[12..16]);
    try std.testing.expectEqual(@as(u8, 2), encoded[19]);
    try std.testing.expectEqual(@as(u8, 2), encoded[23]);
    try std.testing.expectEqualSlices(u8, "IEND", encoded[encoded.len - 8 .. encoded.len - 4]);
}
