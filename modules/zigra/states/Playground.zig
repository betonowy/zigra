const std = @import("std");
const root = @import("../root.zig");
const systems = @import("../systems.zig");
const la = @import("la");
const util = @import("util");
const common = @import("common.zig");

const prototypes = @import("../prototypes.zig");

allocator: std.mem.Allocator,
begin_cam: @Vector(2, i32) = undefined,

rand: std.Random.DefaultPrng,
id_channel: u8 = undefined,

const log = std.log.scoped(.states_Playground);

const InitOptions = struct {
    allocator: std.mem.Allocator,
};

pub fn init(options: InitOptions) !*@This() {
    const self = try options.allocator.create(@This());
    errdefer options.allocator.destroy(self);

    self.* = .{ .allocator = options.allocator, .rand = std.Random.DefaultPrng.init(2137) };
    return self;
}

pub fn deinit(self: *@This()) void {
    self.allocator.destroy(self);
}

pub fn enter(self: *@This(), _: *root.Sequencer, m: *root.Modules) !void {
    util.meta.logFn(log, @src());

    if (m.net.isMaster()) {
        try m.world.sand_sim.loadFromPngFile(
            .{ .coord = .{ -256, -256 }, .size = .{ 512, 512 } },
            "land/TEST_LEVEL_WATERFALL_BIGGAP.png",
        );
    }

    self.id_channel = try m.net.registerChannel(systems.Net.Channel.init(self));
    errdefer m.net.unregisterChannel(self.id_channel);

    const id_sound = m.audio.streams_slut.get("music/t01.ogg") orelse unreachable;
    try m.audio.mixer.playMusic(id_sound);

    _ = try m.background.createId(.{
        .id_vk_sprite = m.vulkan.impl.atlas.getRectIdByPath("images/mountains/cut_04.png").?,
        .bottom_gradient = la.srgbColor(f16, 32.0 / 255.0, 30.0 / 255.0, 52.0 / 255.0, 1),
        .camera_influence = .{ 0.45, 0.45 },
        .offset = .{ 0, 100 },
        .depth = 1,
    });

    _ = try m.background.createId(.{
        .id_vk_sprite = m.vulkan.impl.atlas.getRectIdByPath("images/mountains/cut_03.png").?,
        .bottom_gradient = la.srgbColor(f16, 64.0 / 255.0, 68.0 / 255.0, 92.0 / 255.0, 1),
        .camera_influence = .{ 0.4, 0.4 },
        .offset = .{ 0, 80 },
        .depth = 1,
    });

    _ = try m.background.createId(.{
        .id_vk_sprite = m.vulkan.impl.atlas.getRectIdByPath("images/mountains/cut_02.png").?,
        .bottom_gradient = la.srgbColor(f16, 91.0 / 255.0, 95.0 / 255.0, 121.0 / 255.0, 1),
        .camera_influence = .{ 0.35, 0.35 },
        .offset = .{ 0, 60 },
        .depth = 1,
    });

    _ = try m.background.createId(.{
        .id_vk_sprite = m.vulkan.impl.atlas.getRectIdByPath("images/mountains/cut_01.png").?,
        .bottom_gradient = la.srgbColor(f16, 123.0 / 255.0, 126.0 / 255.0, 154.0 / 255.0, 1),
        .camera_influence = .{ 0.3, 0.3 },
        .depth = 1,
    });

    _ = try m.background.createId(.{
        .id_vk_sprite = m.vulkan.impl.atlas.getRectIdByPath("images/mountains/full_00.png").?,
        .top_gradient = la.srgbColor(f16, 1.0 / 255.0, 17.0 / 255.0, 38.0 / 255.0, 1),
        .bottom_gradient = la.srgbColor(f16, 170.0 / 255.0, 174.0 / 255.0, 203.0 / 255.0, 1),
        .camera_influence = .{ 0.2, 0.2 },
        .offset = .{ 0, 80 },
        .depth = 1,
    });
}

pub fn exit(self: *const @This(), _: *root.Sequencer, m: *root.Modules) void {
    util.meta.logFn(log, @src());

    m.net.unregisterChannel(self.id_channel);
    m.world.sand_sim.clear();
}

pub fn tickEnter(self: *@This(), _: *root.Sequencer, m: *root.Modules) !void {
    try self.tickProcess(m);
}

fn tickProcess(self: *@This(), m: *root.Modules) !void {
    // TODO implement tracing for states
    // var t = common.systemTrace(@This(), @src(), m);
    // defer t.end();

    if (try self.removeSleepingBodies(m) < 10) {
        try self.pushCrateBatch(m, 1);
    }

    switch (m.camera.target) {
        .entity => {},
        else => {
            var iterator = m.bodies.bodies.iterator();

            const uuid_opt: ?util.ecs.Uuid = if (iterator.next()) |body| brk: {
                switch (body.*) {
                    else => @panic("Unimplemented"),
                    .point => |p| break :brk p.id_entity,
                    .rigid => |r| break :brk r.id_entity,
                }
            } else null;

            if (uuid_opt) |uuid| {
                const body = m.bodies.bodies.getByUuid(uuid) orelse unreachable;

                const id_entity = switch (body.*) {
                    .point => |p| p.id_entity,
                    .rigid => |r| r.id_entity,
                    .character => unreachable,
                };

                m.camera.setTarget(.{ .id_entity = .{ .id = id_entity, .m = m } });
            }
        },
    }
}

fn pushCrateBatch(self: *@This(), m: *root.Modules, count: usize) !void {
    for (0..count) |_| {
        // this causes a crate that gets stuck in a wall
        // const random_vel_chunk: @Vector(2, f32) = .{
        //     self.rand.random().floatNorm(f32) * 120,
        //     (self.rand.random().floatNorm(f32) + 1) * -120,
        // };
        const random_vel_chunk: @Vector(2, f32) = .{
            self.rand.random().floatNorm(f32) * 70,
            (self.rand.random().floatNorm(f32) + 1) * -70,
        };

        _ = try prototypes.Crate.default(m, .{ 0, 0 }, random_vel_chunk);
    }
}

fn pushChunkBatch(self: *@This(), m: *root.Modules, count: usize) !void {
    for (0..count) |_| {
        const random_vel_chunk: @Vector(2, f32) = .{
            self.rand.random().floatNorm(f32) * 80,
            (self.rand.random().floatNorm(f32) + 1) * -80,
        };

        _ = try prototypes.Chunk.default(m, .{ 0, 0 }, random_vel_chunk);
    }
}

fn removeSleepingBodies(self: *@This(), m: *root.Modules) !usize {
    const stack_capacity = 128;
    const IndexType = util.ecs.Uuid;

    var stack_fallback = std.heap.stackFallback(stack_capacity * @sizeOf(IndexType), self.allocator);
    var to_remove = std.ArrayList(IndexType).initCapacity(stack_fallback.get(), stack_capacity) catch unreachable;
    defer to_remove.deinit();

    var body_count: usize = 0;
    var iterator = m.bodies.bodies.arr.iterator();
    while (iterator.next()) |body| : (body_count += 1) {
        switch (body.*) {
            else => @panic("Unimplemented"),
            .point => |p| if (p.sleeping) {
                try to_remove.append(p.id_entity);
            } else {
                const transform = m.transform.data.getById(p.id_transform);
                if (transform.pos[1] > 1000) {
                    try to_remove.append(p.id_entity);
                }
            },
            .rigid => |r| if (r.sleeping) {
                try to_remove.append(r.id_entity);
            } else {
                const transform = m.transform.data.getById(r.id_transform);
                if (transform.pos[1] > 1000) {
                    try to_remove.append(r.id_entity);
                }
            },
        }
    }

    for (to_remove.items) |uuid| try m.entities.deferDestroyEntity(uuid);

    return body_count;
}

pub fn netRecv(_: *@This(), _: *root.Modules, _: []const u8) !void {}
