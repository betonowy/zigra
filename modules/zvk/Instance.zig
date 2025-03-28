const builtin = @import("builtin");
const std = @import("std");

const util = @import("util");
const vk = @import("vk");

const PhysicalDevice = @import("PhysicalDevice.zig");
const Surface = @import("Surface.zig");
const vk_api = @import("api.zig");
const VkAllocator = @import("VkAllocator.zig");
const WindowCallbacks = @import("WindowCallbacks.zig");

const log = std.log.scoped(.@"zvk.Instance");

allocator: std.mem.Allocator,
handle: vk.Instance,
get_proc_addr: vk.PfnGetInstanceProcAddr,
vki: *const vk_api.Instance,
vka: ?VkAllocator,
cbs: *const WindowCallbacks,
extensions: []const [*:0]const u8,
layers: []const [*:0]const u8,
vk_debug_msg: ?vk_api.DebugMsg,
debug_msg: ?vk.DebugUtilsMessengerEXT = null,

pub const Options = struct {
    request_validation: bool = false,
    request_debug_utils: bool = false,
};

pub const InitOptions = struct {
    options: Options = .{},
    vk_allocator: ?VkAllocator = null,
};

pub fn init(
    allocator: std.mem.Allocator,
    get_proc_addr: vk.PfnGetInstanceProcAddr,
    cbs: *const WindowCallbacks,
    info: InitOptions,
) !*@This() {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const vkb = vk_api.Base.load(get_proc_addr);

    const debug_extension = "VK_EXT_debug_utils";

    var extensions = std.ArrayList([*:0]const u8).init(arena.allocator());
    try extensions.appendSlice(try cbs.getRequiredInstanceExtensions());

    var options = info.options;

    try extensions.append(debug_extension);

    const validation_layer = "VK_LAYER_KHRONOS_validation";

    const available_layers = try vkb.enumerateInstanceLayerPropertiesAlloc(arena.allocator());

    const validation_available = blk: {
        for (available_layers) |l| {
            const name = l.layer_name[0 .. std.mem.indexOfScalar(u8, &l.layer_name, 0) orelse 0];
            if (std.mem.eql(u8, name, validation_layer)) break :blk true;
        }

        break :blk false;
    };

    var layers = std.ArrayList([*:0]const u8).init(arena.allocator());

    if (validation_available) try layers.append(validation_layer) else {
        options.request_validation = false;
        log.err("Requested {s}, but it is not available - disabling", .{validation_layer});
    }

    const instance = try vkb.createInstance(&.{
        .enabled_extension_count = @intCast(extensions.items.len),
        .pp_enabled_extension_names = extensions.items.ptr,
        .enabled_layer_count = @intCast(layers.items.len),
        .pp_enabled_layer_names = layers.items.ptr,
        .p_application_info = &.{
            .p_application_name = "Zigra",
            .application_version = @bitCast(vk.makeApiVersion(0, 0, 1, 0)),
            .p_engine_name = "Zigra",
            .engine_version = @bitCast(vk.makeApiVersion(0, 0, 1, 0)),
            .api_version = @bitCast(vk.API_VERSION_1_3),
        },
    }, if (info.vk_allocator) |vka| &vka.cbs else null);
    errdefer vk_api.Instance.load(instance, get_proc_addr).destroyInstance(instance, null);

    const vki = try allocator.create(vk_api.Instance);
    errdefer allocator.destroy(vki);

    vki.* = vk_api.Instance.load(instance, get_proc_addr);
    const vk_debug_msg = if (options.request_debug_utils) vk_api.DebugMsg.load(instance, get_proc_addr) else null;

    const p_self = try allocator.create(@This());
    errdefer allocator.destroy(p_self);

    const owned_extensions = try allocator.dupe([*:0]const u8, extensions.items);
    errdefer allocator.free(owned_extensions);

    const owned_layers = try allocator.dupe([*:0]const u8, layers.items);

    p_self.* = .{
        .handle = instance,
        .vki = vki,
        .vka = info.vk_allocator,
        .vk_debug_msg = vk_debug_msg,
        .allocator = allocator,
        .extensions = owned_extensions,
        .layers = owned_layers,
        .get_proc_addr = get_proc_addr,
        .cbs = cbs,
    };

    return p_self;
}

pub fn deinit(self: *@This()) void {
    if (self.debug_msg) |msg| self.vk_debug_msg.?.destroyDebugUtilsMessengerEXT(self.handle, msg, null);
    self.vki.destroyInstance(self.handle, if (self.vka) |vka| &vka.cbs else null);
    if (self.vka) |vka| vka.deinit();
    self.allocator.free(self.layers);
    self.allocator.free(self.extensions);
    self.allocator.destroy(self.vki);
    self.allocator.destroy(self);
}

pub fn maybeEnableDebugMessenger(self: *@This()) void {
    const debug_ctx = struct {
        const log_debug = std.log.scoped(.Vulkan_Ctx_DebugMessenger);

        pub fn cb(
            _: vk.DebugUtilsMessageSeverityFlagsEXT,
            _: vk.DebugUtilsMessageTypeFlagsEXT,
            p_callback_data: ?*const vk.DebugUtilsMessengerCallbackDataEXT,
            _: ?*anyopaque,
        ) callconv(vk.vulkan_call_conv) vk.Bool32 {
            if (p_callback_data) |data| if (data.p_message) |message| {
                log_debug.err("\n{s}\n", .{message});
                util.tried.breakIfDebuggerPresent();
            };

            return vk.FALSE;
        }
    };

    if (self.vk_debug_msg) |vk_debug_msg| {
        self.debug_msg = vk_debug_msg.createDebugUtilsMessengerEXT(self.handle, &.{
            .message_severity = .{
                .error_bit_ext = true,
                .warning_bit_ext = true,
                .info_bit_ext = false,
                .verbose_bit_ext = false,
            },
            .message_type = .{
                .validation_bit_ext = true,
                .performance_bit_ext = true,
                .general_bit_ext = true,
                .device_address_binding_bit_ext = false,
            },
            .pfn_user_callback = debug_ctx.cb,
        }, null) catch {
            log.err("Failed to enable debug messenger", .{});
            return;
        };
    }
}

pub fn pickPhysicalDevice(self: @This(), surface: Surface) !PhysicalDevice {
    var arena = std.heap.ArenaAllocator.init(self.allocator);
    defer arena.deinit();

    const physical_devices = try self.vki.enumeratePhysicalDevicesAlloc(self.handle, arena.allocator());

    for (physical_devices) |pd| {
        var info: vk.PhysicalDeviceProperties2 = .{ .properties = undefined };
        self.vki.getPhysicalDeviceProperties2(pd, &info);
        log.info("Available: {s}, vendor ID: 0x{x}", .{ info.properties.device_name, info.properties.vendor_id });
    }

    for (physical_devices) |pd| if (try self.isDeviceSuitable(pd, surface, &arena)) {
        return .{ .handle = pd, .vki = self.vki, .allocator = self.allocator };
    };

    return error.NoSuitablePhysicalDevice;
}

fn isDeviceSuitable(
    self: @This(),
    pd: vk.PhysicalDevice,
    surface: Surface,
    arena: *std.heap.ArenaAllocator,
) !bool {
    if (builtin.sanitize_thread and builtin.target.os.tag == .linux) {
        const nvidia_vendor_id = 0x10de;

        var p: vk.PhysicalDeviceProperties2 = .{ .properties = undefined };
        self.vki.getPhysicalDeviceProperties2(pd, &p);

        if (p.properties.vendor_id == nvidia_vendor_id) {
            log.warn("Ignoring nvidia drivers on linux system when thread sanitizer is enabled.", .{});
            log.warn("Nvidia closed source driver would otherwise crash with TSan.", .{});
            return false;
        }
    }

    if (!try self.checkQueueFamilies(pd, surface, arena)) return false;
    if (!try self.checkExtensionSupport(pd, arena)) return false;

    const swap_chain_support_details = try self.querySwapchainSupport(
        .{ .handle = pd, .vki = undefined, .allocator = undefined },
        surface,
        arena,
    );

    if (swap_chain_support_details.formats.len == 0) return false;
    if (swap_chain_support_details.modes.len == 0) return false;

    return true;
}

fn checkQueueFamilies(
    self: @This(),
    pd: vk.PhysicalDevice,
    surface: Surface,
    arena: *std.heap.ArenaAllocator,
) !bool {
    const queue_families = try self.vki.getPhysicalDeviceQueueFamilyPropertiesAlloc(
        pd,
        arena.allocator(),
    );

    var has_graphics_compute_family = false;
    var has_present_family = false;

    for (queue_families, 0..) |queue_family, i| {
        if (queue_family.queue_flags.graphics_bit and queue_family.queue_flags.compute_bit) {
            has_graphics_compute_family = true;
        }

        if ((try self.vki.getPhysicalDeviceSurfaceSupportKHR(
            pd,
            @intCast(i),
            surface.handle,
        )) == vk.TRUE) {
            has_present_family = true;
        }
    }

    return has_graphics_compute_family and has_present_family;
}

fn checkExtensionSupport(self: @This(), pd: vk.PhysicalDevice, arena: *std.heap.ArenaAllocator) !bool {
    const properties = try self.vki.enumerateDeviceExtensionPropertiesAlloc(pd, null, arena.allocator());

    var all_available = true;

    const required_device_extensions = [_][*:0]const u8{"VK_KHR_swapchain"};

    for (required_device_extensions) |required_extension| {
        var checked = false;

        for (properties) |property| {
            if (std.mem.orderZ(u8, required_extension, @ptrCast(&property.extension_name)) == .eq) {
                checked = true;
                break;
            }
        }

        if (!checked) {
            all_available = false;
            break;
        }
    }

    return all_available;
}

const SwapchainSupportQuery = struct {
    capabilities: vk.SurfaceCapabilitiesKHR,
    formats: []vk.SurfaceFormatKHR,
    modes: []vk.PresentModeKHR,
};

pub fn querySwapchainSupport(
    self: @This(),
    pd: PhysicalDevice,
    surface: Surface,
    arena: *std.heap.ArenaAllocator,
) !SwapchainSupportQuery {
    return self.internalQuerySwapchainSupport(pd.handle, surface, arena);
}

fn internalQuerySwapchainSupport(
    self: @This(),
    pd: vk.PhysicalDevice,
    surface: Surface,
    arena: *std.heap.ArenaAllocator,
) !SwapchainSupportQuery {
    const capabilities = try self.vki.getPhysicalDeviceSurfaceCapabilitiesKHR(pd, surface.handle);

    var format_count: u32 = undefined;

    if (try self.vki.getPhysicalDeviceSurfaceFormatsKHR(pd, surface.handle, &format_count, null) != .success) {
        return error.SwapchainSupportQueryFailed;
    }

    const formats = try arena.allocator().alloc(vk.SurfaceFormatKHR, format_count);

    if (format_count > 0) {
        if (try self.vki.getPhysicalDeviceSurfaceFormatsKHR(pd, surface.handle, &format_count, formats.ptr) != .success) {
            return error.SwapchainSupportQueryFailed;
        }
    }

    var mode_count: u32 = undefined;

    if (try self.vki.getPhysicalDeviceSurfacePresentModesKHR(pd, surface.handle, &mode_count, null) != .success) {
        return error.SwapchainSupportQueryFailed;
    }

    const modes = try arena.allocator().alloc(vk.PresentModeKHR, mode_count);

    if (mode_count > 0) {
        if (try self.vki.getPhysicalDeviceSurfacePresentModesKHR(pd, surface.handle, &mode_count, modes.ptr) != .success) {
            return error.SwapchainSupportQueryFailed;
        }
    }

    return .{ .capabilities = capabilities, .formats = formats, .modes = modes };
}
