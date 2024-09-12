const std = @import("std");
const lifetime = @import("lifetime");
const systems = @import("systems.zig");
const options = @import("options");

pub const Modules = struct {
    window: systems.Window,
    vulkan: systems.Vulkan,
    world: systems.World,
    playground: systems.Playground,
    time: systems.Time,
    sequencer: systems.Sequencer,
    nuklear: systems.Nuklear,
    debug_ui: if (options.debug_ui) systems.DebugUI else systems.Null,
    sprite_man: systems.SpriteMan,
    entities: systems.Entities,
    transform: systems.Transform,
    bodies: systems.Bodies,
    net: systems.Net,
    audio: systems.Audio,
    camera: systems.Camera,
    background: systems.Background,
};

pub const Context = lifetime.Context(Modules);

test {
    comptime std.testing.refAllDeclsRecursive(@This());
}
