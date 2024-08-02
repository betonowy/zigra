const std = @import("std");

pub fn module(b: *std.Build) *std.Build.Module {
    const use_llvm = b.option(bool, "use-llvm", "Use LLVM backend. (default: true)");
    const profiling = b.option(bool, "profiling", "Enable profiling features. (default: false)");
    const debug_ui = b.option(bool, "debug-ui", "Enable debug ui tools. (default: false)");
    const lock_tick = b.option(bool, "lock-tick", "Locks 1 tick per frame. (default: false)");
    const lock_fps = b.option(f32, "lock-fps", "Limits FPS to this limit. (default: null)");

    const options = b.addOptions();
    options.addOption(bool, "use_llvm", use_llvm orelse true);
    options.addOption(bool, "profiling", profiling orelse false);
    options.addOption(bool, "debug_ui", debug_ui orelse false);
    options.addOption(bool, "lock_tick", lock_tick orelse false);
    options.addOption(?f32, "lock_fps", lock_fps orelse null);
    return options.createModule();
}
