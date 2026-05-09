const builtin = @import("builtin");

pub const is_web = builtin.target.cpu.arch.isWasm() and builtin.target.os.tag == .emscripten;

extern fn emscripten_run_script_int(script: [*:0]const u8) c_int;

pub fn assetRoot() []const u8 {
    return if (is_web) "/assets" else "assets";
}

pub fn canPersistMaps() bool {
    return true;
}

pub fn persistMap(path: []const u8) bool {
    _ = path;
    if (comptime is_web) {
        return emscripten_run_script_int(
            \\(function(){
            \\  try {
            \\    localStorage.setItem('tojam2026.map', FS.readFile('assets/maps/default/map.json', { encoding: 'utf8' }));
            \\    return 1;
            \\  } catch (e) {
            \\    console.error(e);
            \\    return 0;
            \\  }
            \\})()
        ) == 1;
    }
    return true;
}

pub fn restoreMap(path: []const u8) bool {
    _ = path;
    if (comptime is_web) {
        return emscripten_run_script_int(
            \\(function(){
            \\  try {
            \\    var data = localStorage.getItem('tojam2026.map');
            \\    if (data === null) return 0;
            \\    FS.mkdirTree('assets/maps/default');
            \\    FS.writeFile('assets/maps/default/map.json', data);
            \\    return 1;
            \\  } catch (e) {
            \\    console.error(e);
            \\    return 0;
            \\  }
            \\})()
        ) == 1;
    }
    return true;
}
