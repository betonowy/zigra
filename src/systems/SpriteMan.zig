const std = @import("std");
const utils = @import("utils");
const lifetime = @import("../lifetime.zig");
const zigra = @import("../zigra.zig");
const systems = @import("../systems.zig");
const vk_types = @import("Vulkan/types.zig");

const SpriteRef = struct {
    type: SpriteType,
    id_transform: u32,
    id_vk_sprite: u32,
    depth: f32 = 0.1,
};

const SpriteType = enum { Opaque, Blended };

sprite_refs: utils.IdStore(SpriteRef),
entity_id_map: std.AutoHashMap(u32, u32),

pub fn init(allocator: std.mem.Allocator) !@This() {
    return .{
        .sprite_refs = utils.IdStore(SpriteRef).init(allocator),
        .entity_id_map = std.AutoHashMap(u32, u32).init(allocator),
    };
}

pub fn deinit(self: *@This()) void {
    self.entity_id_map.deinit();
    self.sprite_refs.deinit();
}

pub fn createId(self: *@This(), comp: SpriteRef, entity_id: u32) !u32 {
    const internal_id = try self.sprite_refs.push(comp);
    try self.entity_id_map.put(entity_id, internal_id);
    return internal_id;
}

pub fn destroyByEntityId(self: *@This(), id: u32) void {
    const kv = self.entity_id_map.fetchRemove(id) orelse @panic("Entity id not found");
    self.sprite_refs.destroyId(kv.value) catch @panic("Failed to destroy sprite id");
}

pub fn render(self: *@This(), ctx_base: *lifetime.ContextBase) anyerror!void {
    const ctx = ctx_base.parent(zigra.Context);
    const transforms = ctx.systems.transform.transforms.slice().items(.payload);
    var iterator = self.sprite_refs.iterator();

    while (iterator.next()) |fields| {
        const transform: *systems.Transform.Transform = &transforms[fields.payload.id_transform];
        const depth = fields.payload.depth;
        const pos = transform.visual.pos;
        const rot = transform.visual.rot;
        try renderSprite(ctx, pos, -rot, depth, fields.payload.id_vk_sprite);
    }
}

fn renderSprite(ctx: *zigra.Context, pos: @Vector(2, f32), rot: f32, depth: f32, sprite_id: u32) !void {
    const cos = @cos(rot);
    const sin = @sin(rot);

    const rect = ctx.systems.vulkan.impl.atlas.getRectById(sprite_id);

    const w = @as(f32, @floatFromInt(rect.extent.width)) * 0.5;
    const h = @as(f32, @floatFromInt(rect.extent.height)) * 0.5;

    const vx = @Vector(2, f32){ cos * w, -sin * h };
    const vy = @Vector(2, f32){ sin * w, cos * h };

    const p0 = -vx - vy + pos;
    const p1 = vx - vy + pos;
    const p2 = -vx + vy + pos;
    const p3 = vx + vy + pos;

    const vertices = [_]vk_types.VertexData{
        .{
            .point = .{ p0[0], p0[1], depth },
            .color = .{ 1, 1, 1, 1 },
            .uv = .{
                @floatFromInt(rect.offset.x),
                @floatFromInt(rect.offset.y),
            },
        },
        .{
            .point = .{ p1[0], p1[1], depth },
            .color = .{ 1, 1, 1, 1 },
            .uv = .{
                @floatFromInt(rect.offset.x + @as(i32, @intCast(rect.extent.width))),
                @floatFromInt(rect.offset.y),
            },
        },
        .{
            .point = .{ p2[0], p2[1], depth },
            .color = .{ 1, 1, 1, 1 },
            .uv = .{
                @floatFromInt(rect.offset.x),
                @floatFromInt(rect.offset.y + @as(i32, @intCast(rect.extent.height))),
            },
        },
        .{
            .point = .{ p3[0], p3[1], depth },
            .color = .{ 1, 1, 1, 1 },
            .uv = .{
                @floatFromInt(rect.offset.x + @as(i32, @intCast(rect.extent.width))),
                @floatFromInt(rect.offset.y + @as(i32, @intCast(rect.extent.height))),
            },
        },
    };

    try ctx.systems.vulkan.pushCmdTriangle(.{ vertices[0], vertices[1], vertices[2] });
    try ctx.systems.vulkan.pushCmdTriangle(.{ vertices[1], vertices[2], vertices[3] });
}
