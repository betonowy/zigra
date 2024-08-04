const std = @import("std");

const zigra = @import("../root.zig");
const systems = @import("../systems.zig");

fn deinit(_: systems.Entities.Entity, ctx: *zigra.Context, id: u32) void {
    ctx.systems.sprite_man.destroyByEntityId(id);
    ctx.systems.transform.destroyByEntityId(id);
    ctx.systems.bodies.destroyByEntityId(id);
}

pub fn default(ctx: *zigra.Context, pos: @Vector(2, f32), vel: @Vector(2, f32)) !u32 {
    const id_entity = try ctx.systems.entities.create(&deinit);
    const id_vk_sprite = ctx.systems.vulkan.impl.atlas.getRectIdByPath("images/crate_16.png") orelse unreachable;
    // const id_transform = try ctx.systems.transform.createId(.{ .pos = pos, .vel = vel, .rot = std.math.pi / 4.0 }, id_entity);
    const id_transform = try ctx.systems.transform.createId(.{ .pos = pos, .vel = vel }, id_entity);

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
        mesh_ptr.bounciness = 0.45;
        mesh_ptr.friction_dynamic = 0.1;
        mesh_ptr.friction_static = 0.2;
        mesh_ptr.drag = 0.05;

        for (mesh_ptr.points.constSlice()) |p| mesh_ptr.moi += @reduce(.Add, p * p);
    }

    _ = try ctx.systems.sprite_man.createId(.{
        .id_transform = id_transform,
        .id_vk_sprite = id_vk_sprite,
        .type = .Opaque,
    }, id_entity);

    _ = try ctx.systems.bodies.createId(.{ .rigid = .{
        .id_entity = id_entity,
        .id_mesh = id_mesh,
        .id_transform = id_transform,
    } }, id_entity);

    return id_entity;
}
