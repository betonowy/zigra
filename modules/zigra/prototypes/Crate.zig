const zigra = @import("../root.zig");
const systems = @import("../systems.zig");

fn deinit(_: systems.Entities.Entity, ctx: *zigra.Context, id: u32) void {
    ctx.systems.sprite_man.destroyByEntityId(id);
    ctx.systems.transform.destroyByEntityId(id);
    ctx.systems.bodies.destroyByEntityId(id);
}

pub fn default(ctx: *zigra.Context, pos: @Vector(2, f32), vel: @Vector(2, f32)) !u32 {
    const entity = try ctx.systems.entities.create(&deinit);
    const id_vk_sprite = ctx.systems.vulkan.impl.atlas.getRectIdByPath("images/crate_16.png") orelse unreachable;
    const id_transform = try ctx.systems.transform.createId(.{ .pos = pos, .vel = vel }, entity.id);

    const id_mesh = try ctx.systems.bodies.getMeshIdForPath("res/rbm/crate.json");
    const mesh_ptr = ctx.systems.bodies.getMeshById(id_mesh);

    {
        mesh_ptr.points = .{};
        try mesh_ptr.points.appendSlice(&.{
            .{ -8, -8 },
            // .{ 0, -8 },
            .{ 8, -8 },
            // .{ 8, 0 },
            .{ 8, 8 },
            // .{ 0, 8 },
            .{ -8, 8 },
            // .{ -8, 0 },
        });

        mesh_ptr.mass = @floatFromInt(mesh_ptr.points.len + 1);
        mesh_ptr.moi = 0;
        mesh_ptr.bounce_loss = 0.5;
        mesh_ptr.drag = 0.05;

        for (mesh_ptr.points.constSlice()) |p| mesh_ptr.moi += @reduce(.Add, p * p);
    }

    _ = try ctx.systems.sprite_man.createId(.{
        .id_transform = id_transform,
        .id_vk_sprite = id_vk_sprite,
        .type = .Opaque,
    }, entity.id);

    _ = try ctx.systems.bodies.createId(.{ .rigid = .{
        .id_entity = entity.id,
        .id_mesh = id_mesh,
        .id_transform = id_transform,
    } }, entity.id);

    return entity.id;
}
