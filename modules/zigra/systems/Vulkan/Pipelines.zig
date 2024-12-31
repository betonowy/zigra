const std = @import("std");
const zvk = @import("zvk");

pub const ComposeIntermediate = @import("pipelines/ComposeIntermediate.zig");
pub const ComposePresent = @import("pipelines/ComposePresent.zig");
pub const RenderBkg = @import("pipelines/RenderBkg.zig");
pub const RenderLandscape = @import("pipelines/RenderLandscape.zig");
pub const RenderDebugUi = @import("pipelines/RenderDebugUi.zig");
pub const RenderWorld = @import("pipelines/RenderWorld.zig");
pub const ProcessLightmap = @import("pipelines/ProcessLightmap.zig");
pub const Resources = @import("pipelines/Resources.zig");

const Frame = @import("Frame.zig");

resources: Resources,

compose_intermediate: ComposeIntermediate,
compose_present: ComposePresent,
process_lightmap: ProcessLightmap,
render_bkg: RenderBkg,
render_landscape: RenderLandscape,
render_dui: RenderDebugUi,
render_world: RenderWorld,

pub fn init(device: *zvk.Device, swapchain: zvk.Swapchain, o: Frame.Options) !@This() {
    const resources = try Resources.init(device, o);
    errdefer resources.deinit();

    const compose_intermediate = try ComposeIntermediate.init(device, resources);
    errdefer compose_intermediate.deinit();

    const compose_present = try ComposePresent.init(device, swapchain);
    errdefer compose_present.deinit();

    const process_lightmap = try ProcessLightmap.init(device, resources);
    errdefer process_lightmap.deinit();

    const render_bkg = try RenderBkg.init(device);
    errdefer render_bkg.deinit();

    const render_landscape = try RenderLandscape.init(device, resources);
    errdefer render_landscape.deinit();

    const render_dui = try RenderDebugUi.init(device);
    errdefer render_dui.deinit();

    const render_world = try RenderWorld.init(device);
    errdefer render_world.deinit();

    return .{
        .resources = resources,
        .compose_intermediate = compose_intermediate,
        .compose_present = compose_present,
        .process_lightmap = process_lightmap,
        .render_bkg = render_bkg,
        .render_landscape = render_landscape,
        .render_dui = render_dui,
        .render_world = render_world,
    };
}

pub fn deinit(self: @This()) void {
    inline for (comptime std.meta.fieldNames(@This())) |name| {
        @field(self, name).deinit();
    }
}
