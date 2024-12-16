const root = @import("../root.zig");
const systems = @import("../systems.zig");
const std = @import("std");

fn deinit(_: *systems.Entities.Entity, m: *root.Modules, id: u32) void {
    const id_body = m.bodies.bodies.map.get(id);
    std.log.debug("Chunk destructor eid: {}, bid: {?}", .{ id, id_body });
    m.sprite_man.destroyByEntityId(id);
    m.transform.destroyByEntityId(id);
    m.bodies.destroyByEntityId(id);
}

pub fn default(m: *root.Modules, pos: @Vector(2, f32), vel: @Vector(2, f32)) !u32 {
    const id_entity = try m.entities.create(&deinit);
    const id_vk_sprite = m.vulkan.impl.atlas.getRectIdByPath("images/chunk_gold.png") orelse unreachable;
    const id_transform = try m.transform.createId(.{ .pos = pos, .vel = vel }, id_entity);

    _ = try m.sprite_man.createId(.{
        .id_transform = id_transform,
        .id_vk_sprite = id_vk_sprite,
        .type = .Opaque,
    }, id_entity);

    _ = try m.bodies.createId(.{ .point = .{
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

fn terrainCollisionCb(m: *root.Modules, point: *systems.Bodies.Point, pos: @Vector(2, f32), _: @Vector(2, f32)) anyerror!void {
    const sfx_id = m.audio.streams_slut.get("audio/wood/small_explosion_01.ogg") orelse return error.ResNotFound;
    m.audio.mixer.playSound(.{ .id_sound = sfx_id, .pos = pos }) catch {};
    try m.world.sand_sim.explode(@intFromFloat(pos), 12);
    try m.entities.deferDestroyEntity(point.id_entity);
}
