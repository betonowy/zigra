const std = @import("std");
const stb = @cImport(@cInclude("stb/stb_image.h"));

const Cell = @import("./landscape_cell_types.zig").Cell;
const cell_types = @import("./landscape_cell_types.zig").cell_types;

pub const tile_size = 128;

const BoundType = enum { Min, Max };

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
        Rgba.U32(0xff, 0xff, 0x80, 0xff) => cell_types.sand_nb,
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
            if (lhs.type == rhs.type) try std.testing.expect(lhs.subtype != rhs.subtype or lhs.has_bkg != rhs.has_bkg);
        }
    }
}

pub const CellMatrix align(@alignOf(@Vector(16, u8))) = [tile_size][tile_size]Cell;

pub const Tile = struct {
    matrix: CellMatrix,
    coord: @Vector(2, i32),
    touch_count: u32,
    solid_count: u16,
    liquid_count: u16,
    powder_count: u16,
    sleeping: bool,

    pub fn recalculateStats(self: *@This()) void {
        self.solid_count = 0;
        self.liquid_count = 0;
        self.powder_count = 0;
        self.touch_count = 0;
        self.sleeping = false;

        for (self.matrix) |row| for (row) |cell| {
            switch (cell.type) {
                .solid => self.solid_count += 1,
                .liquid => self.liquid_count += 1,
                .powder => self.powder_count += 1,
                else => {},
            }
        };
    }

    pub fn lessPtr(_: void, lhs: *@This(), rhs: *@This()) bool {
        if (lhs.coord[1] < rhs.coord[1]) return true;
        if (lhs.coord[1] == rhs.coord[1] and lhs.coord[0] < rhs.coord[1]) return true;
        return false;
    }

    pub fn getBound(self: *const @This(), comptime bound_type: BoundType) @Vector(2, i32) {
        return switch (bound_type) {
            .Min => self.coord,
            .Max => self.coord + @as(@Vector(2, i32), @splat(tile_size)),
        };
    }

    pub fn hasPoint(self: *const @This(), pos: @Vector(2, i32)) bool {
        return @reduce(.And, self.getBound(.Min) <= pos) and @reduce(.And, self.getBound(.Max) > pos);
    }

    pub fn getLocal(self: *@This(), pos: @Vector(2, u32)) *Cell {
        return &self.matrix[pos[1]][pos[0]];
    }

    pub fn getGlobal(self: *@This(), pos: @Vector(2, i32)) *Cell {
        return self.getLocal(@intCast(pos - self.coord));
    }

    pub fn tryGetGlobal(self: *@This(), pos: @Vector(2, i32)) ?*Cell {
        return if (self.hasPoint(pos)) self.getGlobal(pos) else null;
    }

    pub fn touch(self: *@This()) void {
        self.touch_count += 1;
        self.sleeping = false;
    }

    pub fn touchReset(self: *@This()) void {
        self.touch_count = 0;
    }

    pub fn sleepIfUntouched(self: *@This()) void {
        self.sleeping = self.touch_count == 0;
    }

    pub fn wakeUp(self: *@This()) void {
        self.sleeping = false;
    }

    pub const EdgeNeighbors = std.BoundedArray(@Vector(2, i32), 3);

    pub fn getEdgeNeighbors(self: *@This(), pos: @Vector(2, i32)) EdgeNeighbors {
        var neighbors = EdgeNeighbors.init(0) catch unreachable;
        const local_pos = pos - self.coord;

        const horizontal: i32 = switch (local_pos[0]) {
            tile_size - 1 => 1,
            0 => -1,
            else => 0,
        };

        const vertical: i32 = switch (local_pos[1]) {
            tile_size - 1 => 1,
            0 => -1,
            else => 0,
        };

        if (vertical != 0) neighbors.appendAssumeCapacity(.{ 0, vertical });
        if (horizontal != 0) neighbors.appendAssumeCapacity(.{ horizontal, 0 });
        if (vertical != 0 and horizontal != 0) neighbors.appendAssumeCapacity(.{ horizontal, vertical });

        return neighbors;
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

    pub fn size(self: *const @This()) @Vector(2, i32) {
        const value = @as(i32, 1) << @intCast(self.level);
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

    pub fn hasTile(self: *const @This()) bool {
        return switch (self.child) {
            .tile => |tile| tile != null,
            .nodes => false,
        };
    }

    pub fn isLeaf(self: *const @This()) bool {
        return switch (self.child) {
            .tile => true,
            .nodes => false,
        };
    }

    pub fn countTiles(self: *const @This()) u32 {
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

    /// Assumes child is not a Tile
    pub fn getSubtree(self: *@This(), pos: @Vector(2, i32)) ?*TreeNode {
        const matrix = switch (self.child) {
            .tile => unreachable,
            .nodes => |nodes| nodes,
        };

        for (matrix) |opt_node| if (opt_node) |node| {
            if (node.hasPoint(pos)) return node;
        };

        return null;
    }

    pub fn view(self: *@This()) LandscapeView {
        return LandscapeView{ .target = self };
    }

    pub fn getBound(self: *const @This(), comptime bound_type: BoundType) @Vector(2, i32) {
        return switch (bound_type) {
            .Min => self.coord,
            .Max => self.coord + self.size(),
        };
    }

    pub fn hasPoint(self: *const @This(), pos: @Vector(2, i32)) bool {
        return @reduce(.And, self.getBound(.Min) <= pos) and @reduce(.And, self.getBound(.Max) > pos);
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
iteration: u64,

pub fn init(allocator: std.mem.Allocator) !@This() {
    var self: @This() = undefined;

    self.allocator = allocator;
    self.tile_pool = try TilePool.initPreheated(self.allocator, 4 * 4);
    self.node_pool = try NodePool.initPreheated(self.allocator, 128);
    self.iteration = 0;

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

pub fn getView(self: *@This()) LandscapeView {
    return LandscapeView{ .target = &self.tree };
}

pub fn forEachNode(self: *@This(), actor: anytype) void {
    forEachNodeRecurse(actor, &self.tree);
}

fn forEachNodeRecurse(actor: anytype, node: *const TreeNode) void {
    switch (node.child) {
        .tile => |tile_opt| if (tile_opt) |tile| actor.func(tile),
        .nodes => |nodes| for (nodes) |child| if (child) |subtree| forEachNodeRecurse(actor, subtree),
    }
}

const LandscapeView = struct {
    target: *TreeNode,
    tile_cache: TileCache = TileCache.init(0) catch unreachable,
    stack: NodeStack = NodeStack.init(0) catch unreachable,

    const TileCache = std.BoundedArray(*Tile, 4);
    const NodeStack = std.BoundedArray(*TreeNode, 32);

    pub fn getMutable(self: *@This(), pos: @Vector(2, i32)) !*Cell {
        if (self.tryCacheOnly(pos)) |cell| return cell;
        return try self.tryCacheRefresh(pos) orelse error.PositionNotActive;
    }

    pub fn get(self: *@This(), pos: @Vector(2, i32)) Cell {
        if (self.tryCacheOnly(pos)) |cell| return cell.*;
        return self.tryCacheRefresh(pos) orelse cell_types.air;
    }

    fn tryCacheOnly(self: *@This(), pos: @Vector(2, i32)) ?*Cell {
        for (self.tile_cache.constSlice()) |cached_tile| {
            if (cached_tile.tryGetGlobal(pos)) |cell| return cell;
        }
        return null;
    }

    fn tryCacheRefresh(self: *@This(), pos: @Vector(2, i32)) !?*Cell {
        const tile = try self.getTile(pos) orelse return null;
        if (self.tile_cache.len == self.tile_cache.buffer.len) _ = self.tile_cache.orderedRemove(0);
        self.tile_cache.appendAssumeCapacity(tile);
        return tile.getGlobal(pos);
    }

    pub fn getTile(self: *@This(), pos: @Vector(2, i32)) !?*Tile {
        if (self.stack.len == 0) {
            self.stack.appendAssumeCapacity(self.target);
        }

        var top = self.stack.buffer[self.stack.len - 1];

        while (!top.hasPoint(pos)) {
            if (self.stack.len == 1) return error.PositionOutOfBounds;
            _ = self.stack.pop();
            top = self.stack.buffer[self.stack.len - 1];
        }

        while (!top.isLeaf()) {
            const subtree_opt = top.getSubtree(pos);

            if (subtree_opt) |subtree| {
                try self.stack.append(subtree);
                top = subtree;
                continue;
            }

            return null;
        }

        return top.child.tile.?;
    }
};

pub fn simulate(self: *@This()) !void {
    self.iteration +%= 1;

    //PLAN
    //
    // - Track all damaged regions (potentially needing simulation)
    // - Sort them top to bottom
    // - Scan for interleaving regions and treat them specially
    //
    //ENDPLAN

    const sim_tile_size = @Vector(2, u32){ tile_size / 2, tile_size / 2 };
    _ = sim_tile_size; // autofix

    const sim_extent = NodeExtent{
        .coord = .{ -256, -256 },
        .size = .{ 512, 512 },
    };

    const ensure_extent = NodeExtent{
        .coord = sim_extent.coord - @Vector(2, i32){ 32, 32 },
        .size = sim_extent.size + @Vector(2, u32){ 64, 64 },
    };

    try self.ensureArea(ensure_extent);
    var rand = std.rand.Sfc64.init(self.iteration);
    var view = self.getView();

    var iy: usize = 0;

    while (iy < sim_extent.size[1]) {
        const row_dir: DirOrder = if (iy & 0b1 != 0) .left else .right;

        const origin: @Vector(2, i32) = switch (row_dir) {
            .left => .{
                sim_extent.coord[0] + @as(i32, @intCast(sim_extent.size[0])),
                sim_extent.coord[1] + @as(i32, @intCast(sim_extent.size[1])),
            },
            .right => .{
                sim_extent.coord[0],
                sim_extent.coord[1] + @as(i32, @intCast(sim_extent.size[1])),
            },
        };

        const step_mul: @Vector(2, i32) = switch (row_dir) {
            .left => .{ -1, -1 },
            .right => .{ 1, -1 },
        };

        const row_rand = rand.random().int(usize);

        const check_column_id: i32 = switch (row_dir) {
            .left => tile_size - 1,
            .right => 0,
        };

        var ix: usize = 0;

        var tile_row_is_active: bool = false;

        while (ix < sim_extent.size[0]) {
            const center = origin + @Vector(2, i32){ @intCast(ix), @intCast(iy) } * step_mul;

            if (@mod(center[0], tile_size) == check_column_id) {
                if ((try view.getTile(center)).?.sleeping) {
                    ix += tile_size;
                    continue;
                } else {
                    tile_row_is_active = true;
                }
            }

            try simulateView(&view, center, row_dir, row_rand);

            ix += 1;
        }

        const check_row_id: i32 = tile_size - 1;
        const in_tile_row = @mod(origin[1] + @as(i32, @intCast(iy)) * step_mul[1], tile_size);

        iy += if (in_tile_row == check_row_id and !tile_row_is_active) tile_size else 1;
    }

    const WakeMan = struct {
        pub fn func(_: @This(), tile: *Tile) void {
            tile.sleepIfUntouched();
            tile.touchReset();
        }
    };

    self.forEachNode(WakeMan{});
}

const DirOrder = enum {
    left,
    right,

    pub fn toOffset(self: @This()) @Vector(2, i32) {
        return switch (self) {
            .left => .{ -1, 0 },
            .right => .{ 1, 0 },
        };
    }

    pub fn inversed(self: @This()) DirOrder {
        return switch (self) {
            .left => .right,
            .right => .left,
        };
    }
};

const SwapMove = enum {
    noop,
    swap_r,
    swap_l,
    swap_d,
    swap_ld,
    swap_rd,

    fn toOffset(self: @This()) @Vector(2, i32) {
        return switch (self) {
            .noop => .{ 0, 0 },
            .swap_r => .{ 1, 0 },
            .swap_l => .{ -1, 0 },
            .swap_d => .{ 0, 1 },
            .swap_ld => .{ -1, 1 },
            .swap_rd => .{ 1, 1 },
        };
    }
};

fn simulateView(view: *LandscapeView, pos: @Vector(2, i32), dir_order: DirOrder, rand: usize) !void {
    const current = try view.getMutable(pos);

    switch (current.type) {
        .powder => try simulatePowder(view, current, pos, dir_order),
        .liquid => try simulateLiquid(view, current, pos, dir_order, rand),
        else => {},
    }
}

fn simulatePowder(view: *LandscapeView, current: *Cell, pos: @Vector(2, i32), row_order: DirOrder) !void {
    const swap_orders: []const SwapMove = switch (row_order) {
        .left => &.{ .swap_d, .swap_ld, .swap_rd },
        .right => &.{ .swap_d, .swap_rd, .swap_ld },
    };

    for (swap_orders) |order| {
        const other = try view.getMutable(pos + order.toOffset());
        if (@intFromEnum(other.type) < @intFromEnum(current.type)) {
            if (try view.getTile(pos)) |tile| tile.touch();
            if (try view.getTile(pos + order.toOffset())) |tile| tile.touch();
            return current.swap(other);
        }
    }
}

fn simulateLiquid(view: *LandscapeView, current: *Cell, pos: @Vector(2, i32), dir_order: DirOrder, rand: usize) !void {
    { // trivial case: free spot below
        const other_pos = pos + SwapMove.swap_d.toOffset();
        const other = try view.getMutable(other_pos);

        switch (other.type) {
            .air => {
                const current_tile = (try view.getTile(pos)).?;
                const other_tile = (try view.getTile(other_pos)).?;
                current_tile.touch();
                other_tile.touch();

                {
                    const neighbors = current_tile.getEdgeNeighbors(pos);
                    for (neighbors.constSlice()) |neighbor| {
                        const tile_opt = try view.getTile(pos + neighbor);
                        if (tile_opt) |tile| tile.touch();
                    }
                }
                {
                    const neighbors = other_tile.getEdgeNeighbors(pos);
                    for (neighbors.constSlice()) |neighbor| {
                        const tile_opt = try view.getTile(pos + neighbor);
                        if (tile_opt) |tile| tile.touch();
                    }
                }

                (try view.getTile(pos)).?.touch();
                (try view.getTile(other_pos)).?.touch();

                return current.swap(other);
            },
            else => {},
        }
    }

    const dirs: []const DirOrder = switch (dir_order) {
        .right => &.{ .left, .right },
        .left => &.{ .right, .left },
    };

    const liquid_travel_max: usize = (rand & 0b111) + 1;

    var best_candidate: ?*Cell = null;
    var best_candidate_pos = std.mem.zeroes(@Vector(2, i32));

    brk: for (dirs) |dir| {
        var start_offset = dir.toOffset();

        for (0..liquid_travel_max) |_| {
            const horizontal_pos = start_offset + pos;
            const horizontal = try view.getMutable(horizontal_pos);
            start_offset += dir.toOffset();

            switch (horizontal.type) {
                .air, .liquid => {
                    const horizontal_below_pos = horizontal_pos + @Vector(2, i32){ 0, 1 };
                    const horizontal_below = try view.getMutable(horizontal_below_pos);

                    if (horizontal_below.type == .air) {
                        best_candidate = horizontal_below;
                        best_candidate_pos = horizontal_below_pos;
                        break :brk;
                    } else if (horizontal.type == .air) {
                        best_candidate = horizontal;
                        best_candidate_pos = horizontal_pos;
                    }
                },
                .powder, .solid => break,
            }
        }
    }

    if (best_candidate) |other| {
        const current_tile = (try view.getTile(pos)).?;
        const other_tile = (try view.getTile(best_candidate_pos)).?;
        current_tile.touch();
        other_tile.touch();

        {
            const neighbors = current_tile.getEdgeNeighbors(pos);
            for (neighbors.constSlice()) |neighbor| {
                const tile_opt = try view.getTile(pos + neighbor);
                if (tile_opt) |tile| tile.touch();
            }
        }
        {
            const neighbors = other_tile.getEdgeNeighbors(pos);
            for (neighbors.constSlice()) |neighbor| {
                const tile_opt = try view.getTile(pos + neighbor);
                if (tile_opt) |tile| tile.touch();
            }
        }

        (try view.getTile(pos)).?.touch();
        (try view.getTile(best_candidate_pos)).?.touch();
        current.swap(other);
    }
}

test "Minimal lifetime" {
    var self = try init(std.testing.allocator);
    defer self.deinit();

    try std.testing.expectEqual(16, self.tree.level);
    try self.ensureArea(.{ .coord = .{ -128, -128 }, .size = .{ 256, 256 } });
    try std.testing.expectEqual(4, self.countTiles());

    std.debug.print("\n{any}\n", .{self.tree.size()});

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
