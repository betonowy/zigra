const std = @import("std");

pub fn module(b: *std.Build) *std.Build.Module {
    const profiling = b.option(bool, "profiling", "Enable profiling features.");
    const debug_ui = b.option(bool, "debug-ui", "Enable debug ui tools.");

    const options = b.addOptions();
    options.addOption(bool, "profiling", profiling orelse false);
    options.addOption(bool, "debug_ui", debug_ui orelse false);
    options.addOption(usize, "world_tile_size", 128);
    options.addOption(usize, "gfx_max_commands", 65536);
    return options.createModule();
}
