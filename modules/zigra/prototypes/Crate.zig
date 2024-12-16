const std = @import("std");

const la = @import("la");
const root = @import("../root.zig");
const systems = @import("../systems.zig");
const util = @import("util");

fn deinit(_: *systems.Entities.Entity, m: *root.Modules, uuid: util.ecs.Uuid) void {
    m.sprite_man.destroyByEntityUuid(uuid);
    m.transform.destroyByEntityUuid(uuid);
    m.bodies.destroyByEntityUuid(uuid);
}

pub fn default(m: *root.Modules, pos: @Vector(2, f32), vel: @Vector(2, f32)) !util.ecs.Uuid {
    const id_entity = try m.entities.create(&.{
        .deinit_fn = &deinit,
        .name = "crate_default",
    });

    const id_vk_sprite = m.vulkan.impl.atlas.getRectIdByPath("images/crate_16.png") orelse unreachable;
    const id_transform = try m.transform.createId(.{ .pos = pos, .vel = vel }, id_entity);

    const id_mesh = try m.bodies.getMeshIdForPath("res/rbm/crate.json");
    const mesh_ptr = m.bodies.getMeshById(id_mesh);

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

    _ = try m.sprite_man.createId(.{
        .id_transform = id_transform,
        .id_vk_sprite = id_vk_sprite,
        .type = .Opaque,
    }, id_entity);

    _ = try m.bodies.createId(.{ .rigid = .{
        .id_entity = id_entity,
        .id_mesh = id_mesh,
        .id_transform = id_transform,
        .cb_table = .{ .terrain_collision = &terrainCollisionCb },
    } }, id_entity);

    return id_entity;
}

fn terrainCollisionCb(m: *root.Modules, _: *systems.Bodies.Rigid, pos: @Vector(2, f32), speed: @Vector(2, f32)) anyerror!void {
    const energy_threshold = 500;
    const energy_max_volume = 5000;

    const static = struct {
        var next_entry: u32 = 0;
    };

    const energy = la.sqrLength(speed);
    if (energy < energy_threshold) return;

    const volume = la.clamp((energy - energy_threshold) / (energy_max_volume - energy_threshold), 0, 1);

    const sfx_ids = [_]u32{
        m.audio.streams_slut.get("audio/wood/wood_hit_01.ogg") orelse return error.ResNotFound,
        m.audio.streams_slut.get("audio/wood/wood_hit_02.ogg") orelse return error.ResNotFound,
        m.audio.streams_slut.get("audio/wood/wood_hit_03.ogg") orelse return error.ResNotFound,
        m.audio.streams_slut.get("audio/wood/wood_hit_04.ogg") orelse return error.ResNotFound,
    };

    defer static.next_entry = if (static.next_entry + 1 == sfx_ids.len) 0 else static.next_entry + 1;

    m.audio.mixer.playSound(.{ .id_sound = sfx_ids[static.next_entry], .pos = pos, .volume = volume }) catch {};
}
