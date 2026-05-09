const std = @import("std");

const APP_NAME = "tojam2026";

const C_SOURCES = [_][]const u8{
    "sokol_log.c",
    "sokol_app.c",
    "sokol_gfx.c",
    "sokol_time.c",
    "sokol_audio.c",
    "sokol_gl.c",
    "sokol_debugtext.c",
    "sokol_shape.c",
    "sokol_glue.c",
    "sokol_fetch.c",
    "sokol_imgui.c",
};

const CPP_SOURCES = [_][]const u8{
    "third_party/cimgui/cimgui.cpp",
    "third_party/cimgui/imgui/imgui.cpp",
    "third_party/cimgui/imgui/imgui_demo.cpp",
    "third_party/cimgui/imgui/imgui_draw.cpp",
    "third_party/cimgui/imgui/imgui_tables.cpp",
    "third_party/cimgui/imgui/imgui_widgets.cpp",
};

const Backend = enum {
    metal,
    gl,
    d3d11,
    gles3,
};

const AppMode = enum {
    integrated,
    editor,
    game,
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const app_mode = b.option(
        AppMode,
        "app-mode",
        "Startup mode for native and web builds: integrated, editor, or game",
    ) orelse .integrated;
    const emsdk_root_opt = b.option(
        []const u8,
        "emsdk",
        "Path to emsdk root (required for `zig build web`)",
    );

    const native_sokol_mod = b.createModule(.{
        .root_source_file = b.path("third_party/sokol/sokol.zig"),
        .target = target,
        .optimize = optimize,
    });
    const native_sokol_clib = buildLibSokol(b, "sokol_clib_native", target, optimize, null);
    const native_module = createAppModule(b, target, optimize, native_sokol_mod, null, app_mode);
    native_module.linkLibrary(native_sokol_clib);

    const exe = b.addExecutable(.{
        .name = APP_NAME,
        .root_module = native_module,
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.setCwd(b.path("."));
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    b.step("run", "Run native build").dependOn(&run_cmd.step);
    addNativeRunMode(b, target, optimize, native_sokol_mod, native_sokol_clib, .integrated);
    addNativeRunMode(b, target, optimize, native_sokol_mod, native_sokol_clib, .editor);
    addNativeRunMode(b, target, optimize, native_sokol_mod, native_sokol_clib, .game);

    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_tests = b.addRunArtifact(tests);
    b.step("test", "Run non-rendering unit tests").dependOn(&run_tests.step);

    const web_step = b.step("web", "Build browser bundle in zig-out/web (requires emsdk + emcc)");
    if (emsdk_root_opt) |emsdk_root| {
        const web_target = b.resolveTargetQuery(.{
            .cpu_arch = .wasm32,
            .os_tag = .emscripten,
        });

        const web_sokol_mod = b.createModule(.{
            .root_source_file = b.path("third_party/sokol/sokol.zig"),
            .target = web_target,
            .optimize = optimize,
        });
        const web_sokol_clib = buildLibSokol(
            b,
            "sokol_clib_web",
            web_target,
            optimize,
            emsdk_root,
        );
        const web_module = createAppModule(b, web_target, optimize, web_sokol_mod, emsdk_root, app_mode);
        web_module.linkLibrary(web_sokol_clib);

        const web_lib = b.addLibrary(.{
            .name = "tojam2026_web",
            .root_module = web_module,
        });

        const web_install = makeWebLinkStep(b, .{
            .name = APP_NAME,
            .optimize = optimize,
            .lib_main = web_lib,
            .emsdk_root = emsdk_root,
        });
        web_step.dependOn(&web_install.step);
    } else {
        web_step.dependOn(&b.addFail("`zig build web` requires `-Demsdk=/path/to/emsdk`").step);
    }
}

fn addNativeRunMode(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    native_sokol_mod: *std.Build.Module,
    native_sokol_clib: *std.Build.Step.Compile,
    app_mode: AppMode,
) void {
    const module = createAppModule(b, target, optimize, native_sokol_mod, null, app_mode);
    module.linkLibrary(native_sokol_clib);
    const exe = b.addExecutable(.{
        .name = b.fmt("{s}-{s}", .{ APP_NAME, @tagName(app_mode) }),
        .root_module = module,
    });
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.setCwd(b.path("."));
    b.step(b.fmt("run-{s}", .{@tagName(app_mode)}), b.fmt("Run native build in {s} mode", .{@tagName(app_mode)})).dependOn(&run_cmd.step);
}

fn createAppModule(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    mod_sokol: *std.Build.Module,
    emsdk_root: ?[]const u8,
    app_mode: AppMode,
) *std.Build.Module {
    var cpp_flags_buf: [4][]const u8 = undefined;
    var cpp_flags = std.ArrayListUnmanaged([]const u8).initBuffer(&cpp_flags_buf);
    cpp_flags.appendAssumeCapacity("-std=c++17");
    cpp_flags.appendAssumeCapacity("-fno-sanitize=undefined");

    const cflags: []const []const u8 = if (target.result.os.tag == .emscripten)
        &.{"-fno-sanitize=undefined"}
    else
        &.{};

    const options = b.addOptions();
    options.addOption([]const u8, "app_mode", @tagName(app_mode));

    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .link_libcpp = true,
        .imports = &.{
            .{ .name = "sokol", .module = mod_sokol },
            .{ .name = "build_options", .module = options.createModule() },
        },
    });

    mod.addIncludePath(b.path("third_party/cimgui"));
    mod.addIncludePath(b.path("third_party/cimgui/imgui"));
    mod.addIncludePath(b.path("third_party/stb"));
    mod.addCSourceFile(.{
        .file = b.path("src/stb_image_impl.c"),
        .flags = cflags,
    });

    inline for (CPP_SOURCES) |src| {
        mod.addCSourceFile(.{
            .file = b.path(src),
            .flags = cpp_flags.items,
        });
    }

    if (target.result.os.tag == .emscripten) {
        if (emsdk_root) |root| {
            mod.addSystemIncludePath(.{
                .cwd_relative = b.pathJoin(&.{ root, "upstream", "emscripten", "cache", "sysroot", "include" }),
            });
        }
    }
    return mod;
}

fn buildLibSokol(
    b: *std.Build,
    name: []const u8,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    emsdk_root: ?[]const u8,
) *std.Build.Step.Compile {
    const mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const lib = b.addLibrary(.{
        .name = name,
        .root_module = mod,
    });

    const backend = resolveBackend(target.result);

    var cflags_buf: [10][]const u8 = undefined;
    var cflags = std.ArrayListUnmanaged([]const u8).initBuffer(&cflags_buf);
    cflags.appendAssumeCapacity("-DIMPL");
    cflags.appendAssumeCapacity(backendDefine(backend));

    if (optimize != .Debug) {
        cflags.appendAssumeCapacity("-DNDEBUG");
    }
    if (target.result.os.tag.isDarwin()) {
        cflags.appendAssumeCapacity("-ObjC");
    }
    if (target.result.os.tag == .emscripten) {
        cflags.appendAssumeCapacity("-fno-sanitize=undefined");
        if (emsdk_root) |root| {
            mod.addSystemIncludePath(.{
                .cwd_relative = b.pathJoin(&.{ root, "upstream", "emscripten", "cache", "sysroot", "include" }),
            });
        }
    }

    mod.addIncludePath(b.path("third_party/sokol/c"));
    mod.addIncludePath(b.path("third_party/cimgui"));

    inline for (C_SOURCES) |src| {
        mod.addCSourceFile(.{
            .file = b.path("third_party/sokol/c/" ++ src),
            .flags = cflags.items,
        });
    }

    linkSystemLibs(mod, target.result, backend);
    return lib;
}

fn resolveBackend(target: std.Target) Backend {
    if (target.os.tag.isDarwin()) return .metal;
    if (target.os.tag == .windows) return .d3d11;
    if (target.os.tag == .emscripten) return .gles3;
    return .gl;
}

fn backendDefine(backend: Backend) []const u8 {
    return switch (backend) {
        .metal => "-DSOKOL_METAL",
        .gl => "-DSOKOL_GLCORE",
        .d3d11 => "-DSOKOL_D3D11",
        .gles3 => "-DSOKOL_GLES3",
    };
}

fn linkSystemLibs(mod: *std.Build.Module, target: std.Target, backend: Backend) void {
    if (target.os.tag.isDarwin()) {
        mod.linkFramework("Foundation", .{});
        mod.linkFramework("AudioToolbox", .{});
        mod.linkFramework("Cocoa", .{});
        mod.linkFramework("QuartzCore", .{});
        switch (backend) {
            .metal => mod.linkFramework("Metal", .{}),
            .gl => mod.linkFramework("OpenGL", .{}),
            else => {},
        }
        mod.linkSystemLibrary("c++", .{});
    } else if (target.os.tag == .linux) {
        mod.linkSystemLibrary("asound", .{});
        mod.linkSystemLibrary("GL", .{});
        mod.linkSystemLibrary("X11", .{});
        mod.linkSystemLibrary("Xi", .{});
        mod.linkSystemLibrary("Xcursor", .{});
        mod.linkSystemLibrary("stdc++", .{});
    } else if (target.os.tag == .windows) {
        mod.linkSystemLibrary("kernel32", .{});
        mod.linkSystemLibrary("user32", .{});
        mod.linkSystemLibrary("gdi32", .{});
        mod.linkSystemLibrary("ole32", .{});
        mod.linkSystemLibrary("d3d11", .{});
        mod.linkSystemLibrary("dxgi", .{});
    }
}

const WebLinkOptions = struct {
    name: []const u8,
    optimize: std.builtin.OptimizeMode,
    lib_main: *std.Build.Step.Compile,
    emsdk_root: []const u8,
};

fn makeWebLinkStep(b: *std.Build, options: WebLinkOptions) *std.Build.Step.InstallDir {
    const emcc_py = b.pathJoin(&.{ options.emsdk_root, "upstream", "emscripten", "emcc.py" });
    const emsdk_python = findEmsdkPython(b, options.emsdk_root);
    const emcc = b.addSystemCommand(&.{ emsdk_python, emcc_py });
    emcc.setName("emcc");
    emcc.setEnvironmentVariable("EMSDK", options.emsdk_root);
    emcc.setEnvironmentVariable("EMSDK_PYTHON", emsdk_python);

    if (options.optimize == .Debug) {
        emcc.addArgs(&.{ "-Og", "-sSAFE_HEAP=1", "-sSTACK_OVERFLOW_CHECK=1" });
    } else {
        emcc.addArgs(&.{ "-O3", "-sASSERTIONS=0", "-flto" });
    }

    emcc.addArgs(&.{
        "-sUSE_WEBGL2=1",
        "-sALLOW_MEMORY_GROWTH=1",
        "-sSTACK_SIZE=1MB",
        "--preload-file",
        "assets@/assets",
    });
    emcc.addArg("--shell-file");
    emcc.addFileArg(b.path("web/shell.html"));

    emcc.addArtifactArg(options.lib_main);
    for (options.lib_main.getCompileDependencies(false)) |item| {
        if (item.kind == .lib) {
            emcc.addArtifactArg(item);
        }
    }

    emcc.addArg("-o");
    const out_file = emcc.addOutputFileArg(b.fmt("{s}.html", .{options.name}));

    const install = b.addInstallDirectory(.{
        .source_dir = out_file.dirname(),
        .install_dir = .prefix,
        .install_subdir = "web",
    });
    install.step.dependOn(&emcc.step);
    return install;
}

fn findEmsdkPython(b: *std.Build, emsdk_root: []const u8) []const u8 {
    const python_root = b.pathJoin(&.{ emsdk_root, "python" });
    var dir = std.fs.cwd().openDir(python_root, .{ .iterate = true }) catch {
        return b.pathJoin(&.{ emsdk_root, "python", "3.13.3_64bit", "bin", "python3" });
    };
    defer dir.close();

    var it = dir.iterate();
    while (it.next() catch null) |entry| {
        if (entry.kind != .directory) continue;
        const names = [_][]const u8{ "python3", "python3.13", "python" };
        for (names) |name| {
            const candidate = b.pathJoin(&.{ python_root, entry.name, "bin", name });
            if (std.fs.cwd().access(candidate, .{})) {
                return candidate;
            } else |_| {}
        }
    }
    return b.pathJoin(&.{ emsdk_root, "python", "3.13.3_64bit", "bin", "python3" });
}
