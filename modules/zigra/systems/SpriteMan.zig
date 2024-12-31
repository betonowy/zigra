const std = @import("std");
const util = @import("util");
const lifetime = @import("lifetime");
const tracy = @import("tracy");

const root = @import("../root.zig");
const systems = @import("../systems.zig");
const common = @import("common.zig");

const SpriteRef = struct {
    type: SpriteType,
    id_transform: u32,
    id_vk_sprite: systems.Vulkan.Atlas.TextureReference,
    depth: f32 = 0.1,
};

const SpriteType = enum { Opaque, Blended };

sprite_refs: util.ecs.UuidContainer(SpriteRef),

pub fn init(allocator: std.mem.Allocator) !@This() {
    return .{ .sprite_refs = util.ecs.UuidContainer(SpriteRef).init(allocator) };
}

pub fn deinit(self: *@This()) void {
    self.sprite_refs.deinit();
}

pub fn createId(self: *@This(), comp: SpriteRef, uuid: util.ecs.Uuid) !u32 {
    return try self.sprite_refs.tryPut(uuid, comp);
}

pub fn destroyByEntityUuid(self: *@This(), uuid: util.ecs.Uuid) void {
    self.sprite_refs.remove(uuid) catch {};
}

pub fn render(self: *@This(), m: *root.Modules) anyerror!void {
    var t = common.systemTrace(@This(), @src(), m);
    defer t.end();

    const time_drift = m.time.tickDrift();
    const transforms = m.transform.data.arr.data;

    var iterator = self.sprite_refs.iterator();

    while (iterator.next()) |sprite_ref| {
        const transform = &transforms[sprite_ref.id_transform];
        // const depth = sprite_ref.depth;
        const pos = transform.visualPos(time_drift);
        const rot = transform.visualRot(time_drift);

        try m.vulkan.pushWorldVertices(&createSprite(m, pos, -rot, sprite_ref.id_vk_sprite));
    }
}

fn createSprite(
    m: *root.Modules,
    pos: @Vector(2, f32),
    rot: f32,
    sprite_id: systems.Vulkan.Atlas.TextureReference,
) [6]systems.Vulkan.WorldVertex {
    const rect = m.vulkan.impl.atlas.getRectById(sprite_id);

    const cos = @cos(rot);
    const sin = @sin(rot);

    const w = @as(f32, @floatFromInt(rect.extent.width)) * 0.5;
    const h = @as(f32, @floatFromInt(rect.extent.height)) * 0.5;

    const vx = @Vector(2, f32){ cos * w, -sin * h };
    const vy = @Vector(2, f32){ sin * w, cos * h };

    const p0 = -vx - vy + pos;
    const p1 = vx - vy + pos;
    const p2 = -vx + vy + pos;
    const p3 = vx + vy + pos;

    const v0 = systems.Vulkan.WorldVertex{
        .pos = .{ p0[0], p0[1] },
        .col = .{ 1, 1, 1, 1 },
        .uv = .{
            @floatFromInt(rect.offset.x),
            @floatFromInt(rect.offset.y),
        },
        .tex_ref = .{ sprite_id.layer, sprite_id.index },
    };

    const v1 = systems.Vulkan.WorldVertex{
        .pos = .{ p1[0], p1[1] },
        .col = .{ 1, 1, 1, 1 },
        .uv = .{
            @floatFromInt(rect.offset.x + @as(i32, @intCast(rect.extent.width))),
            @floatFromInt(rect.offset.y),
        },
        .tex_ref = .{ sprite_id.layer, sprite_id.index },
    };

    const v2 = systems.Vulkan.WorldVertex{
        .pos = .{ p2[0], p2[1] },
        .col = .{ 1, 1, 1, 1 },
        .uv = .{
            @floatFromInt(rect.offset.x),
            @floatFromInt(rect.offset.y + @as(i32, @intCast(rect.extent.height))),
        },
        .tex_ref = .{ sprite_id.layer, sprite_id.index },
    };

    const v3 = systems.Vulkan.WorldVertex{
        .pos = .{ p3[0], p3[1] },
        .col = .{ 1, 1, 1, 1 },
        .uv = .{
            @floatFromInt(rect.offset.x + @as(i32, @intCast(rect.extent.width))),
            @floatFromInt(rect.offset.y + @as(i32, @intCast(rect.extent.height))),
        },
        .tex_ref = .{ sprite_id.layer, sprite_id.index },
    };

    return .{ v0, v1, v2, v1, v2, v3 };
}
