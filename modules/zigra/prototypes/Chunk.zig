const zigra = @import("../root.zig");
const systems = @import("../systems.zig");
const std = @import("std");

fn deinit(_: *systems.Entities.Entity, ctx: *zigra.Context, id: u32) void {
    const id_body = ctx.systems.bodies.bodies.map.get(id);
    std.log.debug("Chunk destructor eid: {}, bid: {?}", .{ id, id_body });
    ctx.systems.sprite_man.destroyByEntityId(id);
    ctx.systems.transform.destroyByEntityId(id);
    ctx.systems.bodies.destroyByEntityId(id);
}

pub fn default(ctx: *zigra.Context, pos: @Vector(2, f32), vel: @Vector(2, f32)) !u32 {
    const id_entity = try ctx.systems.entities.create(&deinit);
    const id_vk_sprite = ctx.systems.vulkan.impl.atlas.getRectIdByPath("images/chunk_gold.png") orelse unreachable;
    const id_transform = try ctx.systems.transform.createId(.{ .pos = pos, .vel = vel }, id_entity);

    _ = try ctx.systems.sprite_man.createId(.{
        .id_transform = id_transform,
        .id_vk_sprite = id_vk_sprite,
        .type = .Opaque,
    }, id_entity);

    _ = try ctx.systems.bodies.createId(.{ .point = .{
        .bounce_loss = 0.35,
        .drag = 0.05,
        .id_entity = id_entity,
        .id_transform = id_transform,
        .sleeping = false,
        .weight = 1,
        .cb_table = .{ .terrain_collision = &terrainCollisionCb },
    } }, id_entity);

    return id_entity;
}

const explosion_radius = 25;

fn terrainCollisionCb(ctx: *zigra.Context, point: *systems.Bodies.Point, pos: @Vector(2, f32), _: @Vector(2, f32)) anyerror!void {
    const sfx_id = ctx.systems.audio.streams_slut.get("audio/wood/small_explosion_01.ogg") orelse return error.ResNotFound;
    try ctx.systems.audio.mixer.playSound(.{ .id_sound = sfx_id, .pos = pos });
    try ctx.systems.world.sand_sim.explode(@intFromFloat(pos), 12);
    try ctx.systems.entities.deferDestroyEntity(point.id_entity);
}
