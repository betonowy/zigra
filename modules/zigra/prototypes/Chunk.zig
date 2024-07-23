const zigra = @import("../root.zig");
const systems = @import("../systems.zig");

fn deinit(_: systems.Entities.Entity, ctx: *zigra.Context, id: u32) void {
    ctx.systems.sprite_man.destroyByEntityId(id);
    ctx.systems.transform.destroyByEntityId(id);
    ctx.systems.bodies.destroyByEntityId(id);
}

pub fn default(ctx: *zigra.Context, pos: @Vector(2, f32), vel: @Vector(2, f32)) !u32 {
    const entity = try ctx.systems.entities.create(&deinit);
    const id_vk_sprite = ctx.systems.vulkan.impl.atlas.getRectIdByPath("images/chunk_gold.png") orelse unreachable;
    const id_transform = try ctx.systems.transform.createId(.{ .pos = pos, .vel = vel }, entity.id);

    _ = try ctx.systems.sprite_man.createId(.{
        .id_transform = id_transform,
        .id_vk_sprite = id_vk_sprite,
        .type = .Opaque,
    }, entity.id);

    _ = try ctx.systems.bodies.createId(.{ .point = .{} }, entity.id);

    return entity.id;
}
