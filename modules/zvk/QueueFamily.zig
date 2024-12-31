const std = @import("std");
const Ctx = @import("../Ctx.zig");
const vk = @import("vk");

index: u32,
flags: vk.QueueFlags,
// has_graphics: bool,
// has_compute: bool,
// has_transfer: bool,
// has_present: bool,
