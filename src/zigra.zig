const std = @import("std");
const lifetime = @import("lifetime.zig");
const systems = @import("systems.zig");

pub const Modules = struct {
    window: systems.Window,
    vulkan: systems.Vulkan,
    world: systems.World,
    playground: systems.Playground,
    time: systems.Time,
    sequencer: systems.Sequencer,
    imgui: systems.Nuklear,
    debug_ui: systems.DebugUI,
    sprite_man: systems.SpriteMan,
    entities: systems.Entities,
    transform: systems.Transform,
};

pub const Context = lifetime.Context(Modules);
