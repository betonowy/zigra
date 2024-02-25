const std = @import("std");
const stb = @cImport(@cInclude("stb/stb_image.h"));

const Cell = @import("./landscape_cell_types.zig").Cell;
const cell_types = @import("./landscape_cell_types.zig").cell_types;

pub const tile_size = 128;

test "Cell:is_one_byte" {
    comptime try std.testing.expectEqual(1, @sizeOf(Cell));
    comptime try std.testing.expectEqual(8, @bitSizeOf(Cell));
}

pub const Rgba = packed struct {
    r: u8,
    g: u8,
    b: u8,
    a: u8,

    fn toU32(self: @This()) u32 {
        return @bitCast(self);
    }

    fn U32(r: u8, g: u8, b: u8, a: u8) u32 {
        return (Rgba{ .r = r, .g = g, .b = b, .a = a }).toU32();
    }
};

pub fn rgbaToCell(value: u32) Cell {
    return switch (value) {
        Rgba.U32(0x00, 0x00, 0x00, 0xff) => cell_types.air,
        Rgba.U32(0x40, 0x20, 0x00, 0xff) => cell_types.bkg,
        Rgba.U32(0x80, 0x40, 0x00, 0xff) => cell_types.soil,
        Rgba.U32(0xc0, 0xa8, 0x00, 0xff) => cell_types.gold,
        Rgba.U32(0x40, 0x40, 0x40, 0xff) => cell_types.rock,
        Rgba.U32(0x00, 0x00, 0xc0, 0xff) => cell_types.water,
        Rgba.U32(0x00, 0xff, 0x00, 0xff) => cell_types.acid,
        Rgba.U32(0xff, 0xff, 0x80, 0xff) => cell_types.sand,
        else => @panic("Bad cell coding"),
    };
}

test "cell_types:are_unique" {
    const decls = comptime std.meta.declarations(cell_types);

    inline for (decls, 0..) |a, i| {
        inline for (decls, 0..) |b, j| {
            if (i == j) continue;
            const lhs = @field(cell_types, a.name);
            const rhs = @field(cell_types, b.name);
            if (lhs.type == rhs.type) try std.testing.expect(lhs.subtype != rhs.subtype);
        }
    }
}

pub const CellMatrix align(@alignOf(@Vector(16, u8))) = [tile_size][tile_size]Cell;

pub const Tile = struct {
    matrix: CellMatrix,
    coord: @Vector(2, i32),
    solid_count: u16,
    liquid_count: u16,
    powder_count: u16,
    sleeping: bool,

    pub fn recalculateStats(self: *@This()) void {
        self.solid_count = 0;
        self.liquid_count = 0;
        self.powder_count = 0;

        for (self.matrix) |row| for (row) |cell| {
            switch (cell.type) {
                .solid => self.solid_count += 1,
                .liquid => self.liquid_count += 1,
                .powder => self.powder_count += 1,
                else => {},
            }
        };
    }
};

test "Tile:data_size" {
    comptime try std.testing.expect(std.math.isPowerOfTwo(tile_size));
}

pub const NodeExtent = struct {
    coord: @Vector(2, i32),
    size: @Vector(2, u32),
};

const NodeMatrix = [4]?*TreeNode;

const TreeNode = struct {
    coord: @Vector(2, i32) = .{ 0, 0 },
    level: u32 = 0,

    child: Child = .{ .tile = null },

    const Child = union(enum) {
        tile: ?*Tile,
        nodes: NodeMatrix,
    };

    pub fn size(self: *@This()) @Vector(2, i32) {
        const value = 1 << self.level;
        return .{ value, value };
    }

    pub fn indexToSubtreeExtent(self: *@This(), i: u2) NodeExtent {
        const extent = @as(i32, 1) << @intCast(self.level - 1);
        const extent_v2 = @Vector(2, i32){ extent, extent };
        const offset = self.coord + extent_v2 * @Vector(2, i32){ 0b01 & i, (0b10 & i) >> 1 };

        return .{
            .coord = offset,
            .size = @intCast(extent_v2),
        };
    }

    pub fn hasTile(self: *@This()) bool {
        return switch (self.child) {
            .tile => |tile| tile != null,
            .nodes => false,
        };
    }

    pub fn isLeaf(self: *@This()) bool {
        return switch (self.child) {
            .tile => true,
            .nodes => false,
        };
    }

    pub fn countTiles(self: *@This()) u32 {
        switch (self.child) {
            .tile => return 1,
            .nodes => |opt_nodes| {
                var sum: u32 = 0;
                for (opt_nodes) |opt_node| if (opt_node) |node| {
                    sum += node.countTiles();
                };
                return sum;
            },
        }
    }
};

const TilePool = std.heap.MemoryPoolExtra(Tile, .{});
const NodePool = std.heap.MemoryPoolExtra(TreeNode, .{});
const max_extent = 1 << 16;

allocator: std.mem.Allocator,
pool_arena: std.heap.ArenaAllocator,
tile_pool: TilePool,
node_pool: NodePool,

tree: TreeNode,

pub fn init(allocator: std.mem.Allocator) !@This() {
    var self: @This() = undefined;

    self.allocator = allocator;
    self.tile_pool = try TilePool.initPreheated(self.allocator, 4 * 4);
    self.node_pool = try NodePool.initPreheated(self.allocator, 128);

    self.tree = .{
        .coord = .{ -(max_extent >> 1), -(max_extent >> 1) },
        .level = std.math.log2_int(u32, @intCast(max_extent)),
        .child = .{ .nodes = std.mem.zeroes(NodeMatrix) },
    };

    return self;
}

pub fn deinit(self: *@This()) void {
    self.node_pool.deinit();
    self.tile_pool.deinit();
}

pub fn clear(self: *@This()) void {
    _ = self.node_pool.reset(.retain_capacity);
    _ = self.tile_pool.reset(.retain_capacity);

    self.tree = .{
        .coord = .{ -(max_extent >> 1), -(max_extent >> 1) },
        .level = std.math.log2_int(u32, @intCast(max_extent)),
        .child = .{ .nodes = std.mem.zeroes(NodeMatrix) },
    };
}

pub fn ensureArea(self: *@This(), extent: NodeExtent) !void {
    return ensureAreaTree(self, extent, &self.tree);
}

fn ensureAreaTree(self: *@This(), extent: NodeExtent, tree: *TreeNode) !void {
    if (tree.isLeaf()) return;

    for (tree.child.nodes[0..], 0..) |*opt_node, i| {
        const sub_extent = tree.indexToSubtreeExtent(@intCast(i));
        if (!intersection(sub_extent, extent)) continue;

        if (opt_node.* == null) {
            opt_node.* = try self.node_pool.create();
            opt_node.*.?.* = .{};
        }

        const node = opt_node.*.?;
        node.level = tree.level - 1;
        node.coord = sub_extent.coord;

        if (sub_extent.size[0] == tile_size) {
            if (node.hasTile()) continue;

            const tile_ptr = try self.tile_pool.create();
            tile_ptr.* = std.mem.zeroes(Tile);
            tile_ptr.coord = sub_extent.coord;
            node.child = .{ .tile = tile_ptr };
        } else {
            switch (node.child) {
                .tile => node.child = .{ .nodes = std.mem.zeroes(NodeMatrix) },
                else => {},
            }
            try ensureAreaTree(self, extent, node);
        }
    }
}

fn intersection(a: NodeExtent, b: NodeExtent) bool {
    {
        var a_min = a.coord[0];
        var a_max = a.coord[0] + @as(i32, @intCast(a.size[0]));
        const b_min = b.coord[0];
        const b_max = b.coord[0] + @as(i32, @intCast(b.size[0]));

        if (b_min > a_min) a_min = b_min;
        if (b_max < a_max) a_max = b_max;
        if (a_max <= a_min) return false;
    }
    {
        var a_min = a.coord[1];
        var a_max = a.coord[1] + @as(i32, @intCast(a.size[1]));
        const b_min = b.coord[1];
        const b_max = b.coord[1] + @as(i32, @intCast(b.size[1]));

        if (b_min > a_min) a_min = b_min;
        if (b_max < a_max) a_max = b_max;
        if (a_max <= a_min) return false;
    }
    return true;
}

fn hasPoint(extent: NodeExtent, point: @Vector(2, i32)) bool {
    const size: @Vector(2, i32) = @intCast(extent.size);
    if (@reduce(.Or, point < extent.coord)) return false;
    if (@reduce(.Or, point >= extent.coord + size)) return false;
    return true;
}

pub fn countTiles(self: *@This()) u32 {
    return self.tree.countTiles();
}

pub fn tileCountForArea(_: *@This(), extent: NodeExtent) u32 {
    const aligner = ~((@as(i32, 1) << std.math.log2_int(u16, tile_size)) - 1);

    const aligner_v2: @Vector(2, i32) = @splat(aligner);
    const tile_size_v2: @Vector(2, i32) = @splat(tile_size);

    const start_coord = extent.coord & aligner_v2;
    const end_coord = ((extent.coord + @as(@Vector(2, i32), @intCast(extent.size)) - @Vector(2, i32){ 1, 1 }) & aligner_v2) + tile_size_v2;

    return @intCast(@reduce(.Mul, (end_coord - start_coord) / tile_size_v2));
}

/// Fills tiles with Tile pointers from area in an unspecified order.
/// `tileCountForArea()` tells the required size of the slice.
/// Returns unused slice.
pub fn fillTilesFromArea(self: *@This(), extent: NodeExtent, tiles: []*Tile) ![]*Tile {
    const unused_slice = fillTilesFromAreaTree(self, extent, tiles, &self.tree);
    return tiles[0 .. tiles.len - unused_slice.len];
}

fn fillTilesFromAreaTree(self: *@This(), extent: NodeExtent, tiles: []*Tile, tree: *TreeNode) []*Tile {
    std.debug.assert(!tree.isLeaf());

    var slice = tiles;

    for (tree.child.nodes[0..], 0..) |*opt_node, i| {
        const sub_extent = tree.indexToSubtreeExtent(@intCast(i));
        if (!intersection(sub_extent, extent)) continue;

        const node = opt_node.*.?;

        if (!node.isLeaf()) {
            slice = fillTilesFromAreaTree(self, extent, slice, node);
        } else {
            slice[0] = node.child.tile.?;
            slice = slice[1..];
        }
    }

    return slice;
}

pub fn loadFromBuffer(self: *@This(), extent: NodeExtent, data: []const Cell) !void {
    if (data.len != @reduce(.Mul, extent.size)) return error.ImageSizeDoesntMatch;

    var arena = std.heap.ArenaAllocator.init(self.allocator);
    defer arena.deinit();
    const temp_allocator = arena.allocator();

    self.clear();
    try self.ensureArea(extent);

    const tiles = try temp_allocator.alloc(*Tile, self.tileCountForArea(extent));
    const used = try self.fillTilesFromArea(extent, tiles);
    std.debug.assert(tiles.len == used.len);

    const data_stride = @Vector(2, u32){ 1, extent.size[0] };

    for (used) |tile| {
        for (tile.matrix[0..], 0..) |*row, y| for (row[0..], 0..) |*cell, x| {
            const global = @Vector(2, i32){ @intCast(x), @intCast(y) } + tile.coord;

            if (!hasPoint(extent, global)) {
                cell.* = cell_types.air;
                continue;
            }

            const local: @Vector(2, u32) = @intCast(global - extent.coord);
            cell.* = data[@reduce(.Add, local * data_stride)];
        };

        tile.recalculateStats();
    }
}

pub fn loadFromRgbaImage(self: *@This(), extent: NodeExtent, data: []const u8) !void {
    const count = @reduce(.Mul, extent.size);

    if (data.len != @sizeOf(Rgba) * count) return error.ImageSizeDoesntMatch;

    const rgba_data = @as([*]const Rgba, @ptrCast(@alignCast(data.ptr)))[0..count];
    const cell_data = try self.allocator.alloc(Cell, count);
    defer self.allocator.free(cell_data);

    for (rgba_data, cell_data) |src, *dst| dst.* = rgbaToCell(src.toU32());

    return loadFromBuffer(self, extent, cell_data);
}

pub fn loadFromPngFile(self: *@This(), extent: NodeExtent, path: []const u8) !void {
    const cstr = try self.allocator.dupeZ(u8, path);
    defer self.allocator.free(cstr);

    var x: c_int = undefined;
    var y: c_int = undefined;
    var c: c_int = undefined;

    const rgba = @as([*]u8, @ptrCast(stb.stbi_load(cstr, &x, &y, &c, 4)));
    defer stb.stbi_image_free(rgba);

    return self.loadFromRgbaImage(extent, rgba[0..@intCast(x * y * 4)]);
}

test "Minimal lifetime" {
    var self = try init(std.testing.allocator);
    defer self.deinit();

    try std.testing.expectEqual(16, self.tree.level);
    try self.ensureArea(.{ .coord = .{ -128, -128 }, .size = .{ 256, 256 } });
    try std.testing.expectEqual(4, self.countTiles());

    try std.testing.expectEqual(4, self.tileCountForArea(.{ .coord = .{ -128, -128 }, .size = .{ 256, 256 } }));
    try std.testing.expectEqual(9, self.tileCountForArea(.{ .coord = .{ -127, -127 }, .size = .{ 256, 256 } }));
    try std.testing.expectEqual(9, self.tileCountForArea(.{ .coord = .{ -129, -129 }, .size = .{ 256, 256 } }));
    try std.testing.expectEqual(4, self.tileCountForArea(.{ .coord = .{ -127, -127 }, .size = .{ 255, 255 } }));
    try std.testing.expectEqual(1, self.tileCountForArea(.{ .coord = .{ 0, 0 }, .size = .{ 128, 128 } }));
    try std.testing.expectEqual(4, self.tileCountForArea(.{ .coord = .{ -1, -1 }, .size = .{ 2, 2 } }));
    try std.testing.expectEqual(1, self.tileCountForArea(.{ .coord = .{ 0, 0 }, .size = .{ 1, 1 } }));

    {
        const extent = NodeExtent{ .coord = .{ -1, -1 }, .size = .{ 2, 2 } };

        const count = self.tileCountForArea(extent);
        try std.testing.expectEqual(4, count);

        var tiles: [4]*Tile = undefined;
        const filled = try self.fillTilesFromArea(extent, tiles[0..]);
        try std.testing.expectEqual(4, filled.len);
    }
    {
        var tiles: [1]*Tile = undefined;
        var buffer: [24 * 24]Cell = undefined;

        for (buffer[0..], 0..) |*cell, i| {
            cell.* = if (i & 0b1 == 1) cell_types.air else cell_types.soil;
        }

        try self.loadFromBuffer(.{ .coord = .{ -16, -16 }, .size = .{ 24, 24 } }, buffer[0..]);
        {
            const tile = (try self.fillTilesFromArea(.{ .coord = .{ -16, -16 }, .size = .{ 16, 16 } }, &tiles))[0];

            try std.testing.expectEqual(0, tile.liquid_count);
            try std.testing.expectEqual(0, tile.powder_count);
            try std.testing.expectEqual(16 * 16 / 2, tile.solid_count);
        }
        {
            const tile = (try self.fillTilesFromArea(.{ .coord = .{ 0, -16 }, .size = .{ 8, 16 } }, &tiles))[0];

            try std.testing.expectEqual(0, tile.liquid_count);
            try std.testing.expectEqual(0, tile.powder_count);
            try std.testing.expectEqual(8 * 16 / 2, tile.solid_count);
        }
        {
            const tile = (try self.fillTilesFromArea(.{ .coord = .{ -16, 0 }, .size = .{ 16, 8 } }, &tiles))[0];

            try std.testing.expectEqual(0, tile.liquid_count);
            try std.testing.expectEqual(0, tile.powder_count);
            try std.testing.expectEqual(16 * 8 / 2, tile.solid_count);
        }
        {
            const tile = (try self.fillTilesFromArea(.{ .coord = .{ 0, 0 }, .size = .{ 8, 8 } }, &tiles))[0];

            try std.testing.expectEqual(0, tile.liquid_count);
            try std.testing.expectEqual(0, tile.powder_count);
            try std.testing.expectEqual(8 * 8 / 2, tile.solid_count);
        }
    }
}
