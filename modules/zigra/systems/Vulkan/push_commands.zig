const Backend = @import("Backend.zig");
const types = @import("types.zig");

pub fn pushWorldLine(self: *Backend, points: [2]@Vector(2, f32), color: @Vector(4, f16), depth: f32, alpha: @Vector(2, f16)) !void {
    try self.upload_line_data.append(self.allocator, .{
        .points = points,
        .color = color,
        .depth = depth,
        .alpha_gradient = alpha,
    });
}

pub fn pushWorldVertex(self: *Backend, vertex: types.VertexData) !void {
    try self.upload_triangle_data.append(self.allocator, vertex);
}

pub fn pushGuiChar(self: *Backend, data: types.TextData) !void {
    const base_char_offset: @Vector(2, f32) = .{
        @floatFromInt(self.font.offset.x + @as(i32, @intCast((data.char % Backend.font_h_count) * Backend.font_width))),
        @floatFromInt(self.font.offset.y + @as(i32, @intCast((data.char / Backend.font_h_count) * Backend.font_height))),
    };

    const base_char_extent: @Vector(2, f32) = .{
        @floatFromInt(Backend.font_width),
        @floatFromInt(Backend.font_height),
    };

    const vertices: [4]types.VertexData = .{
        .{
            .color = data.color,
            .point = data.offset,
            .uv = base_char_offset,
        },
        .{
            .color = data.color,
            .point = data.offset + @Vector(3, f32){ base_char_extent[0], 0, 0 },
            .uv = base_char_offset + @Vector(2, f32){ base_char_extent[0], 0 },
        },
        .{
            .color = data.color,
            .point = data.offset + @Vector(3, f32){ 0, base_char_extent[1], 0 },
            .uv = base_char_offset + @Vector(2, f32){ 0, base_char_extent[1] },
        },
        .{
            .color = data.color,
            .point = data.offset + @Vector(3, f32){ base_char_extent[0], base_char_extent[1], 0 },
            .uv = base_char_offset + @Vector(2, f32){ base_char_extent[0], base_char_extent[1] },
        },
    };

    try pushGuiTriangle(self, vertices[0..3]);
    try pushGuiTriangleEdit(self, vertices[1..4]);
}

fn pushGuiScissorEdit(self: *Backend, scissor: types.GuiHeader.Scissor) void {
    self.upload_gui_data.items[self.upload_gui_data.items.len - 1].scissor = scissor;
}

fn pushGuiScissorAppend(self: *Backend, scissor: types.GuiHeader.Scissor) !void {
    try self.upload_gui_data.append(self.allocator, .{ .scissor = scissor });
}

pub fn pushGuiScissor(self: *Backend, scissor: types.GuiHeader.Scissor) !void {
    if (self.upload_gui_data.getLastOrNull()) |last_cmd| {
        switch (last_cmd) {
            .scissor => pushGuiScissorEdit(self, scissor),
            else => try pushGuiScissorAppend(self, scissor),
        }
    } else {
        try pushGuiScissorAppend(self, scissor);
    }
}

fn pushGuiTriangleEdit(self: *Backend, data: []const types.VertexData) !void {
    self.upload_gui_data.items[self.upload_gui_data.items.len - 1].triangles.end += @intCast(data.len);
    try self.upload_gui_vertices.appendSlice(self.allocator, data);
}

fn pushGuiTriangleAppend(self: *Backend, data: []const types.VertexData) !void {
    try self.upload_gui_data.append(self.allocator, .{
        .triangles = .{
            .begin = @intCast(self.upload_gui_vertices.items.len),
            .end = @intCast(self.upload_gui_vertices.items.len + data.len),
        },
    });
    try self.upload_gui_vertices.appendSlice(self.allocator, data);
}

pub fn pushGuiTriangle(self: *Backend, data: []const types.VertexData) !void {
    if (self.upload_gui_data.getLastOrNull()) |last_cmd| {
        switch (last_cmd) {
            .triangles => try pushGuiTriangleEdit(self, data),
            else => try pushGuiTriangleAppend(self, data),
        }
    } else {
        try pushGuiTriangleAppend(self, data);
    }
}

fn pushGuiLineEdit(self: *Backend, data: []const types.VertexData) !void {
    self.upload_gui_data.items[self.upload_gui_data.items.len - 1].lines.end += @intCast(data.len);
    try self.upload_gui_vertices.appendSlice(self.allocator, data);
}

fn pushGuiLineAppend(self: *Backend, data: []const types.VertexData) !void {
    try self.upload_gui_data.append(self.allocator, .{
        .lines = .{
            .begin = @intCast(self.upload_gui_vertices.items.len),
            .end = @intCast(self.upload_gui_vertices.items.len + data.len),
        },
    });
    try self.upload_gui_vertices.appendSlice(self.allocator, data);
}

pub fn pushGuiLine(self: *Backend, data: []const types.VertexData) !void {
    if (self.upload_gui_data.getLastOrNull()) |last_cmd| {
        switch (last_cmd) {
            .lines => try pushGuiLineEdit(self, data),
            else => try pushGuiLineAppend(self, data),
        }
    } else {
        try pushGuiLineAppend(self, data);
    }
}
