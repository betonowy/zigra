const std = @import("std");

const systems = @import("../systems.zig");
const lifetime = @import("lifetime");
const zigra = @import("../root.zig");
const la = @import("la");

const prototypes = @import("../prototypes.zig");

allocator: std.mem.Allocator,
begin_cam: @Vector(2, i32) = undefined,

active_bodies: std.ArrayList(u32),

rand: std.Random.DefaultPrng,
id_channel: u32 = undefined,

pub fn init(allocator: std.mem.Allocator) !@This() {
    return .{
        .allocator = allocator,
        .rand = std.Random.DefaultPrng.init(395828523321213),
        .active_bodies = std.ArrayList(u32).init(allocator),
    };
}

pub fn systemInit(self: *@This(), ctx_base: *lifetime.ContextBase) anyerror!void {
    const ctx = ctx_base.parent(zigra.Context);

    if (ctx.systems.net.isMaster()) {
        try ctx.systems.world.sand_sim.loadFromPngFile(
            .{ .coord = .{ -256, -256 }, .size = .{ 512, 512 } },
            "land/TEST_LEVEL_WATERFALL_BIGGAP.png",
        );
    }

    self.id_channel = try ctx.systems.net.registerChannel(systems.Net.Channel.init(self));

    const id_sound = ctx.systems.audio.streams_slut.get("music/t01.ogg") orelse unreachable;
    try ctx.systems.audio.mixer.playMusic(id_sound);

    _ = try ctx.systems.background.createId(.{
        .id_vk_sprite = ctx.systems.vulkan.impl.atlas.getRectIdByPath("images/mountains/full_00.png"),
        .top_gradient = la.srgbColor(f16, 1.0 / 255.0, 17.0 / 255.0, 38.0 / 255.0, 1),
        .bottom_gradient = la.srgbColor(f16, 170.0 / 255.0, 174.0 / 255.0, 203.0 / 255.0, 1),
        .camera_influence = .{ 0.2, 0.2 },
        .offset = .{ 0, 80 },
        .depth = 1,
    });

    _ = try ctx.systems.background.createId(.{
        .id_vk_sprite = ctx.systems.vulkan.impl.atlas.getRectIdByPath("images/mountains/cut_01.png"),
        .bottom_gradient = la.srgbColor(f16, 123.0 / 255.0, 126.0 / 255.0, 154.0 / 255.0, 1),
        .camera_influence = .{ 0.3, 0.3 },
        .depth = 1,
    });

    _ = try ctx.systems.background.createId(.{
        .id_vk_sprite = ctx.systems.vulkan.impl.atlas.getRectIdByPath("images/mountains/cut_02.png"),
        .bottom_gradient = la.srgbColor(f16, 91.0 / 255.0, 95.0 / 255.0, 121.0 / 255.0, 1),
        .camera_influence = .{ 0.35, 0.35 },
        .offset = .{ 0, 60 },
        .depth = 1,
    });

    _ = try ctx.systems.background.createId(.{
        .id_vk_sprite = ctx.systems.vulkan.impl.atlas.getRectIdByPath("images/mountains/cut_03.png"),
        .bottom_gradient = la.srgbColor(f16, 64.0 / 255.0, 68.0 / 255.0, 92.0 / 255.0, 1),
        .camera_influence = .{ 0.4, 0.4 },
        .offset = .{ 0, 80 },
        .depth = 1,
    });

    _ = try ctx.systems.background.createId(.{
        .id_vk_sprite = ctx.systems.vulkan.impl.atlas.getRectIdByPath("images/mountains/cut_04.png"),
        .bottom_gradient = la.srgbColor(f16, 32.0 / 255.0, 30.0 / 255.0, 52.0 / 255.0, 1),
        .camera_influence = .{ 0.45, 0.45 },
        .offset = .{ 0, 100 },
        .depth = 1,
    });
}

pub fn systemDeinit(_: *@This(), _: *lifetime.ContextBase) anyerror!void {}

pub fn deinit(self: *@This()) void {
    self.active_bodies.deinit();
}

pub fn tickProcess(self: *@This(), ctx_base: *lifetime.ContextBase) anyerror!void {
    const ctx = ctx_base.parent(zigra.Context);

    if (self.active_bodies.items.len <= 2) {
        try self.pushCrateBatch(ctx, 1);
        try self.pushChunkBatch(ctx, 1);
    }

    try self.removeSleepingBodies(ctx);

    switch (ctx.systems.camera.target) {
        .entity => {},
        else => {
            if (self.active_bodies.items.len == 0) return;

            const id = self.active_bodies.items[0];
            const body = ctx.systems.bodies.bodies.getById(id);

            const id_entity = switch (body.*) {
                .point => |p| p.id_entity,
                .rigid => |r| r.id_entity,
                .character => unreachable,
            };

            ctx.systems.camera.setTarget(.{ .id_entity = .{ .id = id_entity, .ctx = ctx } });
        },
    }
}

fn pushCrateBatch(self: *@This(), ctx: *zigra.Context, count: usize) !void {
    for (0..count) |_| {
        const random_vel_chunk: @Vector(2, f32) = .{
            self.rand.random().floatNorm(f32) * 80,
            (self.rand.random().floatNorm(f32) + 1) * -80,
        };

        const entity_id = try prototypes.Crate.default(ctx, .{ 0, 0 }, random_vel_chunk);
        const body_id = ctx.systems.bodies.bodies.map.get(entity_id).?;

        try self.active_bodies.append(body_id);
    }
}

fn pushChunkBatch(self: *@This(), ctx: *zigra.Context, count: usize) !void {
    for (0..count) |_| {
        const random_vel_chunk: @Vector(2, f32) = .{
            self.rand.random().floatNorm(f32) * 80,
            (self.rand.random().floatNorm(f32) + 1) * -80,
        };

        const entity_id = try prototypes.Chunk.default(ctx, .{ 0, 0 }, random_vel_chunk);
        const body_id = ctx.systems.bodies.bodies.map.get(entity_id).?;

        try self.active_bodies.append(body_id);
    }
}

fn removeSleepingBodies(self: *@This(), ctx: *zigra.Context) !void {
    const stack_capacity = 128;
    const IndexType = usize;

    var stack_fallback = std.heap.stackFallback(stack_capacity * @sizeOf(IndexType), self.allocator);
    var to_remove = std.ArrayList(IndexType).initCapacity(stack_fallback.get(), stack_capacity) catch unreachable;
    defer to_remove.deinit();

    for (self.active_bodies.items, 0..) |id, i| {
        const body = ctx.systems.bodies.bodies.getById(id);

        switch (body.*) {
            else => @panic("Unimplemented"),
            .point => |p| if (p.sleeping) {
                ctx.systems.entities.destroyEntity(ctx, p.id_entity);
                try to_remove.append(i);
            } else {
                const transform = ctx.systems.transform.data.getById(p.id_transform);
                if (transform.pos[1] > 1000) {
                    ctx.systems.entities.destroyEntity(ctx, p.id_entity);
                    try to_remove.append(i);
                }
            },
            .rigid => |r| if (r.sleeping) {
                ctx.systems.entities.destroyEntity(ctx, r.id_entity);
                try to_remove.append(i);
            } else {
                const transform = ctx.systems.transform.data.getById(r.id_transform);
                if (transform.pos[1] > 1000) {
                    ctx.systems.entities.destroyEntity(ctx, r.id_entity);
                    try to_remove.append(i);
                }
            },
        }
    }

    var iterator = std.mem.reverseIterator(to_remove.items);
    while (iterator.next()) |i| _ = self.active_bodies.swapRemove(i);
}

pub fn netRecv(self: *@This(), ctx_base: *lifetime.ContextBase, data: []const u8) !void {
    _ = self; // autofix
    _ = data; // autofix
    const ctx = ctx_base.parent(zigra.Context);
    _ = ctx; // autofix
}
