const std = @import("std");
const sokol = @import("sokol");
const saudio = sokol.audio;

pub const SfxId = enum {
    click_confirm,
    click_cancel,
    hover_tick,
    panel_open,
    panel_close,
    tool_cycle,
    computer_ack,
    build_start,
    build_complete,
    building_destroyed,
    heal_pulse,
    invalid_action,
    portal_loop_stinger,
    resource_tick,
    teleport,
    artillery_fire,
    artillery_impact,
    infantry_attack,
    unit_hit_metal,
    unit_move_ack,
};

pub const MusicId = enum {
    simple_bgm_loop,
    into_the_stars,
    scifi,
    scifi2,
    scifitrimmed,
    scifi_city_ambient_loop,
};

const SfxCount = @typeInfo(SfxId).@"enum".fields.len;
const MusicCount = @typeInfo(MusicId).@"enum".fields.len;
const MaxVoices = 32;

const Clip = struct {
    samples: []f32 = &.{},
    frames: usize = 0,
    channels: u16 = 0,

    fn deinit(self: *Clip, allocator: std.mem.Allocator) void {
        allocator.free(self.samples);
        self.* = .{};
    }

    fn sample(self: *const Clip, frame: usize, channel: usize) f32 {
        if (self.frames == 0 or self.channels == 0) return 0;
        const src_channel = if (self.channels == 1) 0 else @min(channel, @as(usize, self.channels - 1));
        return self.samples[frame * self.channels + src_channel];
    }
};

const Voice = struct {
    active: bool = false,
    sfx: SfxId = .click_confirm,
    cursor: usize = 0,
    gain: f32 = 1.0,
};

const MusicState = struct {
    active: bool = false,
    track: MusicId = .simple_bgm_loop,
    cursor: usize = 0,
    gain: f32 = 0.45,
    loop: bool = true,
};

pub const Engine = struct {
    allocator: std.mem.Allocator = undefined,
    sfx: [SfxCount]Clip = [_]Clip{.{}} ** SfxCount,
    music: [MusicCount]Clip = [_]Clip{.{}} ** MusicCount,
    voices: [MaxVoices]Voice = [_]Voice{.{}} ** MaxVoices,
    music_state: MusicState = .{},
    ambient_state: MusicState = .{ .track = .scifi_city_ambient_loop, .gain = 0.12, .loop = true },
    sfx_volume: f32 = 1.0,
    music_volume: f32 = 1.0,
    ambient_volume: f32 = 1.0,
    mutex: std.Thread.Mutex = .{},
    initialized: bool = false,
    valid: bool = false,
    output_channels: usize = 2,

    pub fn init(self: *Engine, allocator: std.mem.Allocator, asset_root: []const u8) void {
        self.* = .{ .allocator = allocator };
        saudio.setup(.{
            .sample_rate = 44100,
            .num_channels = 2,
            .stream_userdata_cb = streamCallback,
            .user_data = self,
        });
        self.initialized = true;
        self.valid = saudio.isvalid();
        self.output_channels = @intCast(@max(1, saudio.channels()));
        self.loadAssets(asset_root) catch |err| {
            std.log.warn("audio assets failed to load: {s}", .{@errorName(err)});
        };
    }

    pub fn deinit(self: *Engine) void {
        if (self.initialized) {
            saudio.shutdown();
            self.initialized = false;
            self.valid = false;
        }
        for (&self.sfx) |*clip| clip.deinit(self.allocator);
        for (&self.music) |*clip| clip.deinit(self.allocator);
    }

    pub fn playSfx(self: *Engine, id: SfxId) void {
        self.playSfxGain(id, 1.0);
    }

    pub fn playSfxGain(self: *Engine, id: SfxId, gain: f32) void {
        if (!self.valid) return;
        if (self.sfx[indexOf(id)].frames == 0) return;
        self.mutex.lock();
        defer self.mutex.unlock();

        var slot: *Voice = &self.voices[0];
        for (&self.voices) |*voice| {
            if (!voice.active) {
                slot = voice;
                break;
            }
        }
        slot.* = .{
            .active = true,
            .sfx = id,
            .cursor = 0,
            .gain = gain,
        };
    }

    pub fn playMusic(self: *Engine, id: MusicId, gain: f32, loop: bool) void {
        if (!self.valid) return;
        if (self.music[indexOf(id)].frames == 0) return;
        self.mutex.lock();
        defer self.mutex.unlock();
        self.music_state = .{
            .active = true,
            .track = id,
            .cursor = 0,
            .gain = gain,
            .loop = loop,
        };
    }

    pub fn playAmbient(self: *Engine, id: MusicId, gain: f32) void {
        if (!self.valid) return;
        if (self.music[indexOf(id)].frames == 0) return;
        self.mutex.lock();
        defer self.mutex.unlock();
        self.ambient_state = .{
            .active = true,
            .track = id,
            .cursor = 0,
            .gain = gain,
            .loop = true,
        };
    }

    pub fn stopMusic(self: *Engine) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.music_state.active = false;
    }

    pub fn stopAmbient(self: *Engine) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.ambient_state.active = false;
    }

    pub fn musicActive(self: *Engine) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.music_state.active;
    }

    pub fn setSfxVolume(self: *Engine, volume: f32) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.sfx_volume = std.math.clamp(volume, 0, 1);
    }

    pub fn setMusicVolume(self: *Engine, volume: f32) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.music_volume = std.math.clamp(volume, 0, 1);
    }

    pub fn setAmbientVolume(self: *Engine, volume: f32) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.ambient_volume = std.math.clamp(volume, 0, 1);
    }

    fn loadAssets(self: *Engine, asset_root: []const u8) !void {
        try self.loadSfx(asset_root, .click_confirm, "audio/sfx/ui/click_confirm.wav");
        try self.loadSfx(asset_root, .click_cancel, "audio/sfx/ui/click_cancel.wav");
        try self.loadSfx(asset_root, .hover_tick, "audio/sfx/ui/hover_tick.wav");
        try self.loadSfx(asset_root, .panel_open, "audio/sfx/ui/panel_open.wav");
        try self.loadSfx(asset_root, .panel_close, "audio/sfx/ui/panel_close.wav");
        try self.loadSfx(asset_root, .tool_cycle, "audio/sfx/ui/tool_cycle.wav");
        try self.loadSfx(asset_root, .computer_ack, "audio/sfx/ui/computer_ack.wav");
        try self.loadSfx(asset_root, .build_start, "audio/sfx/gameplay/build_start.wav");
        try self.loadSfx(asset_root, .build_complete, "audio/sfx/gameplay/build_complete.wav");
        try self.loadSfx(asset_root, .building_destroyed, "audio/sfx/gameplay/building_destroyed.wav");
        try self.loadSfx(asset_root, .heal_pulse, "audio/sfx/gameplay/heal_pulse.wav");
        try self.loadSfx(asset_root, .invalid_action, "audio/sfx/gameplay/invalid_action.wav");
        try self.loadSfx(asset_root, .portal_loop_stinger, "audio/sfx/gameplay/portal_loop_stinger.wav");
        try self.loadSfx(asset_root, .resource_tick, "audio/sfx/gameplay/resource_tick.wav");
        try self.loadSfx(asset_root, .teleport, "audio/sfx/gameplay/teleport.wav");
        try self.loadSfx(asset_root, .artillery_fire, "audio/sfx/units/artillery_fire.wav");
        try self.loadSfx(asset_root, .artillery_impact, "audio/sfx/units/artillery_impact.wav");
        try self.loadSfx(asset_root, .infantry_attack, "audio/sfx/units/infantry_attack.wav");
        try self.loadSfx(asset_root, .unit_hit_metal, "audio/sfx/units/unit_hit_metal.wav");
        try self.loadSfx(asset_root, .unit_move_ack, "audio/sfx/units/unit_move_ack.wav");

        try self.loadMusic(asset_root, .simple_bgm_loop, "audio/music/simple_bgm_loop.wav");
        try self.loadMusic(asset_root, .into_the_stars, "audio/music/into_the_stars.wav");
        try self.loadMusic(asset_root, .scifi, "audio/music/scifi.wav");
        try self.loadMusic(asset_root, .scifi2, "audio/music/scifi2.wav");
        try self.loadMusic(asset_root, .scifitrimmed, "audio/music/scifitrimmed.wav");
        try self.loadMusic(asset_root, .scifi_city_ambient_loop, "audio/ambience/scifi_city_ambient_loop.wav");
    }

    fn loadSfx(self: *Engine, asset_root: []const u8, id: SfxId, rel_path: []const u8) !void {
        self.sfx[indexOf(id)] = try loadWav(self.allocator, asset_root, rel_path);
    }

    fn loadMusic(self: *Engine, asset_root: []const u8, id: MusicId, rel_path: []const u8) !void {
        self.music[indexOf(id)] = try loadWav(self.allocator, asset_root, rel_path);
    }

    fn mix(self: *Engine, out: []f32, frames: usize, channels: usize) void {
        @memset(out, 0);
        self.mutex.lock();
        defer self.mutex.unlock();

        self.mixTrackState(&self.ambient_state, out, frames, channels, self.ambient_volume);
        self.mixTrackState(&self.music_state, out, frames, channels, self.music_volume);

        for (&self.voices) |*voice| {
            if (!voice.active) continue;
            const clip = &self.sfx[indexOf(voice.sfx)];
            for (0..frames) |frame| {
                if (voice.cursor >= clip.frames) {
                    voice.active = false;
                    break;
                }
                for (0..channels) |channel| {
                    out[frame * channels + channel] += clip.sample(voice.cursor, channel) * voice.gain * self.sfx_volume;
                }
                voice.cursor += 1;
            }
        }

        for (out) |*sample| {
            sample.* = std.math.clamp(sample.*, -1.0, 1.0);
        }
    }

    fn mixTrackState(self: *Engine, state: *MusicState, out: []f32, frames: usize, channels: usize, master_gain: f32) void {
        if (!state.active) return;
        const clip = &self.music[indexOf(state.track)];
        if (clip.frames == 0) {
            state.active = false;
            return;
        }

        var frame: usize = 0;
        while (frame < frames and state.active) : (frame += 1) {
            if (state.cursor >= clip.frames) {
                if (state.loop) {
                    state.cursor = 0;
                } else {
                    state.active = false;
                    break;
                }
            }
            for (0..channels) |channel| {
                out[frame * channels + channel] += clip.sample(state.cursor, channel) * state.gain * master_gain;
            }
            state.cursor += 1;
        }
    }
};

fn streamCallback(buffer: [*c]f32, num_frames: i32, num_channels: i32, user_data: ?*anyopaque) callconv(.c) void {
    if (user_data == null or num_frames <= 0 or num_channels <= 0) return;
    const engine: *Engine = @ptrCast(@alignCast(user_data.?));
    const frames: usize = @intCast(num_frames);
    const channels: usize = @intCast(num_channels);
    engine.mix(buffer[0 .. frames * channels], frames, channels);
}

fn indexOf(value: anytype) usize {
    return @intFromEnum(value);
}

fn loadWav(allocator: std.mem.Allocator, asset_root: []const u8, rel_path: []const u8) !Clip {
    const path = try std.fs.path.join(allocator, &.{ asset_root, rel_path });
    defer allocator.free(path);
    const bytes = try std.fs.cwd().readFileAlloc(allocator, path, 16 * 1024 * 1024);
    defer allocator.free(bytes);
    return decodeWav(allocator, bytes);
}

fn decodeWav(allocator: std.mem.Allocator, bytes: []const u8) !Clip {
    if (bytes.len < 12 or !std.mem.eql(u8, bytes[0..4], "RIFF") or !std.mem.eql(u8, bytes[8..12], "WAVE")) {
        return error.InvalidWav;
    }

    var channels: u16 = 0;
    var bits_per_sample: u16 = 0;
    var audio_format: u16 = 0;
    var data: []const u8 = &.{};
    var offset: usize = 12;
    while (offset + 8 <= bytes.len) {
        const chunk_id = bytes[offset .. offset + 4];
        const chunk_size = readU32(bytes[offset + 4 .. offset + 8]);
        offset += 8;
        if (offset + chunk_size > bytes.len) return error.InvalidWav;
        const chunk = bytes[offset .. offset + chunk_size];
        if (std.mem.eql(u8, chunk_id, "fmt ")) {
            if (chunk.len < 16) return error.InvalidWav;
            audio_format = readU16(chunk[0..2]);
            channels = readU16(chunk[2..4]);
            bits_per_sample = readU16(chunk[14..16]);
        } else if (std.mem.eql(u8, chunk_id, "data")) {
            data = chunk;
        }
        offset += chunk_size + (chunk_size & 1);
    }

    if (audio_format != 1 or (channels != 1 and channels != 2) or bits_per_sample != 16 or data.len == 0) {
        return error.UnsupportedWav;
    }

    const sample_count = data.len / 2;
    const samples = try allocator.alloc(f32, sample_count);
    var i: usize = 0;
    while (i < sample_count) : (i += 1) {
        const lo = data[i * 2];
        const hi = data[i * 2 + 1];
        const raw: i16 = @bitCast(@as(u16, lo) | (@as(u16, hi) << 8));
        samples[i] = @as(f32, @floatFromInt(raw)) / 32768.0;
    }

    return .{
        .samples = samples,
        .frames = sample_count / channels,
        .channels = channels,
    };
}

fn readU16(bytes: []const u8) u16 {
    return @as(u16, bytes[0]) | (@as(u16, bytes[1]) << 8);
}

fn readU32(bytes: []const u8) u32 {
    return @as(u32, bytes[0]) |
        (@as(u32, bytes[1]) << 8) |
        (@as(u32, bytes[2]) << 16) |
        (@as(u32, bytes[3]) << 24);
}
