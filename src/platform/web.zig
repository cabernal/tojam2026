const builtin = @import("builtin");

pub const is_web = builtin.target.cpu.arch.isWasm() and builtin.target.os.tag == .emscripten;

pub fn assetRoot() []const u8 {
    return if (is_web) "/assets" else "assets";
}

pub fn canPersistMaps() bool {
    return !is_web;
}
