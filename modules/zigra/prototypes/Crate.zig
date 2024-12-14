const std = @import("std");

const la = @import("la");
const zigra = @import("../root.zig");
const systems = @import("../systems.zig");
const util = @import("utils");

fn deinit(_: *systems.Entities.Entity, ctx: *zigra.Context, uuid: util.ecs.Uuid) void {
    ctx.systems.sprite_man.destroyByEntityUuid(uuid);
    ctx.systems.transform.destroyByEntityUuid(uuid);
    ctx.systems.bodies.destroyByEntityUuid(uuid);
}

pub fn default(ctx: *zigra.Context, pos: @Vector(2, f32), vel: @Vector(2, f32)) !util.ecs.Uuid {
    const id_entity = try ctx.systems.entities.create(&.{
        .deinit_fn = &deinit,
        .name = "crate_default",
    });

    const id_vk_sprite = ctx.systems.vulkan.impl.atlas.getRectIdByPath("images/crate_16.png") orelse unreachable;
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
        .cb_table = .{ .terrain_collision = &terrainCollisionCb },
    } }, id_entity);

    return id_entity;
}

fn terrainCollisionCb(ctx: *zigra.Context, _: *systems.Bodies.Rigid, pos: @Vector(2, f32), speed: @Vector(2, f32)) anyerror!void {
    const energy_threshold = 500;
    const energy_max_volume = 5000;

    const static = struct {
        var next_entry: u32 = 0;
    };

    const energy = la.sqrLength(speed);
    if (energy < energy_threshold) return;

    const volume = la.clamp((energy - energy_threshold) / (energy_max_volume - energy_threshold), 0, 1);

    const sfx_ids = [_]u32{
        ctx.systems.audio.streams_slut.get("audio/wood/wood_hit_01.ogg") orelse return error.ResNotFound,
        ctx.systems.audio.streams_slut.get("audio/wood/wood_hit_02.ogg") orelse return error.ResNotFound,
        ctx.systems.audio.streams_slut.get("audio/wood/wood_hit_03.ogg") orelse return error.ResNotFound,
        ctx.systems.audio.streams_slut.get("audio/wood/wood_hit_04.ogg") orelse return error.ResNotFound,
    };

    defer static.next_entry = if (static.next_entry + 1 == sfx_ids.len) 0 else static.next_entry + 1;

    ctx.systems.audio.mixer.playSound(.{ .id_sound = sfx_ids[static.next_entry], .pos = pos, .volume = volume }) catch {};
}
