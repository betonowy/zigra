const std = @import("std");
const lifetime = @import("lifetime");
const systems = @import("systems.zig");
const options = @import("options");
const util = @import("util");

pub const states = @import("states.zig");

pub const Modules = struct {
    thread_pool: systems.ThreadPool = undefined,
    time: systems.Time,
    entities: systems.Entities,
    audio: systems.Audio,
    window: systems.Window,
    vulkan: systems.Vulkan,
    net: systems.Net,
    sprite_man: systems.SpriteMan,
    world: systems.World,
    transform: systems.Transform,
    bodies: systems.Bodies,
    nuklear: systems.Nuklear,
    debug_ui: if (options.debug_ui) systems.DebugUI else systems.Null,
    camera: systems.Camera,
    background: systems.Background,
};

pub const Sequencer = util.stack_states.Sequencer(Modules);

test {
    comptime std.testing.refAllDeclsRecursive(@This());
}
