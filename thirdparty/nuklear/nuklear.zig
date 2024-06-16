const std = @import("std");
const c = @cImport(@cInclude("include.h"));

pub const Context = c.struct_nk_context;
pub const Allocator = c.struct_nk_allocator;
pub const UserFont = c.struct_nk_user_font;
pub const Bool = c.nk_bool;
pub const Rect = c.struct_nk_rect;
pub const Flags = c.nk_flags;
pub const Handle = c.nk_handle;
pub const Color = c.struct_nk_color;

pub const Command = c.struct_nk_command;
pub const CommandScissor = c.struct_nk_command_scissor;
pub const CommandLine = c.struct_nk_command_line;
pub const CommandCurve = c.struct_nk_command_curve;
pub const CommandRect = c.struct_nk_command_rect;
pub const CommandRectFilled = c.struct_nk_command_rect_filled;
pub const CommandRectMultiColor = c.struct_nk_command_rect_multi_color;
pub const CommandCircle = c.struct_nk_command_circle;
pub const CommandCircleFilled = c.struct_nk_command_circle_filled;
pub const CommandArc = c.struct_nk_command_arc;
pub const CommandArcFilled = c.struct_nk_command_arc_filled;
pub const CommandTriangle = c.struct_nk_command_triangle;
pub const CommandTriangleFilled = c.struct_nk_command_triangle_filled;
pub const CommandPolygon = c.struct_nk_command_polygon;
pub const CommandPolygonFilled = c.struct_nk_command_polygon_filled;
pub const CommandPolyline = c.struct_nk_command_polyline;
pub const CommandText = c.struct_nk_command_text;
pub const CommandImage = c.struct_nk_command_image;
pub const CommandCustom = c.struct_nk_command_custom;

pub const command_nop = c.NK_COMMAND_NOP;
pub const command_scissor = c.NK_COMMAND_SCISSOR;
pub const command_line = c.NK_COMMAND_LINE;
pub const command_curve = c.NK_COMMAND_CURVE;
pub const command_rect = c.NK_COMMAND_RECT;
pub const command_rect_filled = c.NK_COMMAND_RECT_FILLED;
pub const command_rect_multi_color = c.NK_COMMAND_RECT_MULTI_COLOR;
pub const command_circle = c.NK_COMMAND_CIRCLE;
pub const command_circle_filled = c.NK_COMMAND_CIRCLE_FILLED;
pub const command_arc = c.NK_COMMAND_ARC;
pub const command_arc_filled = c.NK_COMMAND_ARC_FILLED;
pub const command_triangle = c.NK_COMMAND_TRIANGLE;
pub const command_triangle_filled = c.NK_COMMAND_TRIANGLE_FILLED;
pub const command_polygon = c.NK_COMMAND_POLYGON;
pub const command_polygon_filled = c.NK_COMMAND_POLYGON_FILLED;
pub const command_polyline = c.NK_COMMAND_POLYLINE;
pub const command_text = c.NK_COMMAND_TEXT;
pub const command_image = c.NK_COMMAND_IMAGE;
pub const command_custom = c.NK_COMMAND_CUSTOM;

pub const button_left = c.NK_BUTTON_LEFT;
pub const button_right = c.NK_BUTTON_RIGHT;
pub const button_middle = c.NK_BUTTON_MIDDLE;

pub const WindowFlag = enum(u32) {
    closeable = c.NK_WINDOW_CLOSABLE,
    scalable = c.NK_WINDOW_SCALABLE,
    movable = c.NK_WINDOW_MOVABLE,
    _,
};

pub const shown = c.NK_SHOWN;
pub const hidden = c.NK_HIDDEN;

pub const CollapseState = enum(u32) {
    maximized = c.NK_MAXIMIZED,
    minimized = c.NK_MINIMIZED,
};

pub const TreeType = enum(u32) {
    node = c.NK_TREE_NODE,
    tab = c.NK_TREE_TAB,
};

pub const text_left = c.NK_TEXT_LEFT;

pub const TextWidthCb = c.nk_text_width_f;
pub const GlyphQueryCb = c.nk_query_font_glyph_f;

pub fn initFixed(ctx: *Context, mem: []u8, user_font: ?*const UserFont) !void {
    if (c.nk_init_fixed(ctx, mem.ptr, mem.len, user_font) == c.nk_false) return error.NkInitFailed;
}

pub fn deinit(ctx: *Context) void {
    c.nk_free(ctx);
}

pub fn flagConcat(comptime flags: anytype) @TypeOf(flags[0]) {
    var a = flags[0];
    inline for (flags[0..]) |f| {
        var v: u32 = @intFromEnum(a);
        v |= @intFromEnum(f);
        a = @enumFromInt(v);
    }
    return a;
}

pub fn begin(ctx: *Context, title: [*:0]const u8, bounds: Rect, comptime flags: []const WindowFlag) bool {
    return c.nk_begin(ctx, title, bounds, @intFromEnum(flagConcat(flags))) == c.nk_true;
}

pub fn end(ctx: *Context) void {
    c.nk_end(ctx);
}

pub fn layoutRowStatic(ctx: *Context, height: f32, item_width: i32, cols: i32) void {
    c.nk_layout_row_static(ctx, height, @intCast(item_width), @intCast(cols));
}

pub fn layoutRowDynamic(ctx: *Context, height: f32, cols: i32) void {
    c.nk_layout_row_dynamic(ctx, height, cols);
}

pub fn buttonLabel(ctx: *Context, title: [*:0]const u8) bool {
    return c.nk_button_label(ctx, title) == c.nk_true;
}

pub fn label(ctx: *Context, title: [*:0]const u8, flags: c.nk_flags) void {
    c.nk_label(ctx, title, flags);
}

pub fn labelColored(ctx: *Context, title: [*:0]const u8, flags: c.nk_flags, color: c.nk_color) void {
    c.nk_label_colored(ctx, title, flags, color);
}

pub fn treeBeginHashed(
    ctx: *Context,
    tree_type: TreeType,
    title: [*:0]const u8,
    comptime src_location: std.builtin.SourceLocation,
    id: c_int,
    state: CollapseState,
) bool {
    const hash = std.fmt.comptimePrint("{}{s}{}{s}", .{
        src_location.line,
        src_location.fn_name,
        src_location.column,
        src_location.file,
    });

    return c.nk_tree_push_hashed(
        ctx,
        @intFromEnum(tree_type),
        title,
        @intFromEnum(state),
        hash.ptr,
        hash.len,
        id,
    ) == c.nk_true;
}

pub fn treePop(ctx: *Context) void {
    c.nk_tree_pop(ctx);
}

pub fn clear(ctx: *Context) void {
    c.nk_clear(ctx);
}

pub fn DrawCallback(UserDataType: type) type {
    return fn (ctx: *Context, cmd: *const Command, user_data: UserDataType) anyerror!void;
}

pub fn forEachDrawCommand(ctx: *Context, UserDataType: type, user_data: UserDataType, callback: DrawCallback(UserDataType)) !void {
    var cmd: ?*const Command = @ptrCast(c.nk__begin(ctx));

    while (cmd != null) : (cmd = @ptrCast(c.nk__next(ctx, cmd))) {
        try callback(ctx, cmd.?, user_data);
    }
}

pub fn inputBegin(ctx: *Context) void {
    c.nk_input_begin(ctx);
}

pub fn inputEnd(ctx: *Context) void {
    c.nk_input_end(ctx);
}

pub fn inputMotion(ctx: *Context, x: i32, y: i32) void {
    c.nk_input_motion(ctx, @intCast(x), @intCast(y));
}

pub fn inputButton(ctx: *Context, x: i32, y: i32, button: u32, down: bool) void {
    c.nk_input_button(ctx, @intCast(button), @intCast(x), @intCast(y), if (down) c.nk_true else c.nk_false);
}
