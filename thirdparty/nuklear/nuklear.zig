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

pub const KEY_SHIFT: c_int = 1;
pub const KEY_CTRL: c_int = 2;
pub const KEY_DEL: c_int = 3;
pub const KEY_ENTER: c_int = 4;
pub const KEY_TAB: c_int = 5;
pub const KEY_BACKSPACE: c_int = 6;
pub const KEY_COPY: c_int = 7;
pub const KEY_CUT: c_int = 8;
pub const KEY_PASTE: c_int = 9;
pub const KEY_UP: c_int = 10;
pub const KEY_DOWN: c_int = 11;
pub const KEY_LEFT: c_int = 12;
pub const KEY_RIGHT: c_int = 13;
pub const KEY_TEXT_INSERT_MODE: c_int = 14;
pub const KEY_TEXT_REPLACE_MODE: c_int = 15;
pub const KEY_TEXT_RESET_MODE: c_int = 16;
pub const KEY_TEXT_LINE_START: c_int = 17;
pub const KEY_TEXT_LINE_END: c_int = 18;
pub const KEY_TEXT_START: c_int = 19;
pub const KEY_TEXT_END: c_int = 20;
pub const KEY_TEXT_UNDO: c_int = 21;
pub const KEY_TEXT_REDO: c_int = 22;
pub const KEY_TEXT_SELECT_ALL: c_int = 23;
pub const KEY_TEXT_WORD_LEFT: c_int = 24;
pub const KEY_TEXT_WORD_RIGHT: c_int = 25;
pub const KEY_SCROLL_START: c_int = 26;
pub const KEY_SCROLL_END: c_int = 27;
pub const KEY_SCROLL_DOWN: c_int = 28;
pub const KEY_SCROLL_UP: c_int = 29;

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

pub const ChartType = enum(u32) {
    lines = c.NK_CHART_LINES,
    columns = c.NK_CHART_COLUMN,
};

pub const text_left = c.NK_TEXT_LEFT;
pub const text_center = c.NK_TEXT_CENTERED;
pub const text_right = c.NK_TEXT_RIGHT;

pub const TextWidthCb = c.nk_text_width_f;
pub const GlyphQueryCb = c.nk_query_font_glyph_f;

pub fn initFixed(ctx: *Context, mem: []u8, user_font: ?*const UserFont) !void {
    if (!c.nk_init_fixed(ctx, mem.ptr, mem.len, user_font)) return error.NkInitFailed;
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
    return c.nk_begin(ctx, title, bounds, @intFromEnum(flagConcat(flags)));
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
    return c.nk_button_label(ctx, title);
}

pub fn rule(ctx: *Context, color: Color) void {
    c.nk_rule_horizontal(ctx, color, false);
}

pub fn buttonLabelColored(
    ctx: *Context,
    title: [*:0]const u8,
    color_normal: c.nk_color,
    color_hover: c.nk_color,
    color_active: c.nk_color,
) bool {
    if (!c.nk_style_push_style_item(ctx, &ctx.style.button.normal, c.nk_style_item_color(color_normal))) unreachable;
    if (!c.nk_style_push_style_item(ctx, &ctx.style.button.hover, c.nk_style_item_color(color_hover))) unreachable;
    if (!c.nk_style_push_style_item(ctx, &ctx.style.button.active, c.nk_style_item_color(color_active))) unreachable;

    defer for (0..3) |_| if (!c.nk_style_pop_style_item(ctx)) unreachable;

    return c.nk_button_label(ctx, title);
}

pub fn label(ctx: *Context, title: [*:0]const u8, flags: c.nk_flags) void {
    c.nk_label(ctx, title, flags);
}

pub fn labelColored(ctx: *Context, title: [*:0]const u8, flags: c.nk_flags, color: c.nk_color) void {
    c.nk_label_colored(ctx, title, flags, color);
}

pub fn textField(ctx: *Context, buffer: []u8, plen: anytype) void {
    var len: c_int = @intCast(plen.*);
    defer plen.* = @intCast(len);
    _ = c.nk_edit_string(ctx, c.NK_EDIT_BOX | c.NK_EDIT_AUTO_SELECT, buffer.ptr, &len, @intCast(buffer.len), null);
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
    );
}

pub fn treePop(ctx: *Context) void {
    c.nk_tree_pop(ctx);
}

pub fn chartBegin(ctx: *Context, chart_type: ChartType, count: i32, min: f32, max: f32) bool {
    return c.nk_chart_begin(ctx, @intFromEnum(chart_type), @intCast(count), min, max);
}

pub fn chartBeginColored(ctx: *Context, chart_type: ChartType, base: Color, active: Color, count: i32, min: f32, max: f32) bool {
    return c.nk_chart_begin_colored(ctx, @intFromEnum(chart_type), base, active, @intCast(count), min, max);
}

pub fn chartEnd(ctx: *Context) void {
    c.nk_chart_end(ctx);
}

pub fn chartPush(ctx: *Context, value: f32) void {
    _ = c.nk_chart_push(ctx, value);
}

pub fn propertyI32(ctx: *Context, name: [*:0]const u8, min: i32, val: *i32, max: i32, step: i32, inc_per_pixel: f32) void {
    c.nk_property_int(ctx, name, @intCast(min), @ptrCast(val), @intCast(max), @intCast(step), inc_per_pixel);
}

pub fn sliderI32(ctx: *Context, min: i32, val: *i32, max: i32, step: i32) bool {
    return c.nk_slider_int(ctx, @intCast(min), @ptrCast(val), @intCast(max), @intCast(step));
}

pub fn radioLabel(ctx: *Context, name: [*:0]const u8, active: *bool) void {
    _ = c.nk_radio_label(ctx, name, active);
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
    c.nk_input_button(ctx, @intCast(button), @intCast(x), @intCast(y), down);
}

pub fn inputScroll(ctx: *Context, x: f32, y: f32) void {
    c.nk_input_scroll(ctx, .{ .x = x, .y = y });
}

pub fn inputChars(ctx: *Context, chars: []const u21) void {
    for (chars) |char| c.nk_input_unicode(ctx, char);
}

pub fn inputKey(ctx: *Context, key: i32, state: bool) void {
    c.nk_input_key(ctx, @intCast(key), state);
}

pub fn hasFocus(ctx: *Context) bool {
    return c.nk_item_is_any_active(ctx);
}
