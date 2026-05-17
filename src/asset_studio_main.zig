const std = @import("std");
const builtin = @import("builtin");
const sokol = @import("sokol");
const sapp = sokol.app;
const studio = @import("asset_studio/app.zig");

const is_web = builtin.target.cpu.arch.isWasm() and builtin.target.os.tag == .emscripten;
var gpa = if (is_web) {} else std.heap.GeneralPurposeAllocator(.{}){};
var app: studio.AppState = .{};

fn init() callconv(.c) void {
    if (is_web) {
        app.init(std.heap.c_allocator);
    } else {
        app.init(gpa.allocator());
    }
}

fn frame() callconv(.c) void {
    app.frame();
}

fn cleanup() callconv(.c) void {
    app.cleanup();
    if (!is_web) {
        _ = gpa.deinit();
    }
}

fn event(ev: [*c]const sapp.Event) callconv(.c) void {
    if (ev == null) return;
    app.handleEvent(ev[0]);
}

pub fn main() void {
    var desc = studio.appDesc();
    desc.init_cb = init;
    desc.frame_cb = frame;
    desc.cleanup_cb = cleanup;
    desc.event_cb = event;
    sapp.run(desc);
}
