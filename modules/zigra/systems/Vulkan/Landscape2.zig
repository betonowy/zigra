const std = @import("std");

const tracy = @import("tracy");
const utils = @import("util");
const vk = @import("vk");

const types = @import("types.zig");
const stb = @cImport(@cInclude("stb/stb_image.h"));

const Backend = @import("Backend.zig");

const frame_margin = 256;
const frame_width = Backend.frame_target_width + frame_margin * 2;
const frame_height = Backend.frame_target_height + frame_margin * 2;
