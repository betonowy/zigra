const std = @import("std");
const id_containers = @import("id_containers.zig");

pub const IdArray = id_containers.IdArray;
pub const ExtIdMappedIdArray = id_containers.ExtIdMappedIdArray;

pub const DDA = @import("DDA.zig");
pub const KBI = @import("KBI.zig");
pub const integrators = @import("integrators.zig");
pub const meta = @import("meta.zig");
pub const cb = @import("cb.zig");
pub const tried = @import("tried.zig");
pub const dtors = @import("dtors.zig");
pub const mt = @import("mt.zig");
pub const mio = @import("mio.zig");
pub const CLikeAllocator = @import("CLikeAllocator.zig");

test {
    comptime std.testing.refAllDecls(id_containers);
    comptime std.testing.refAllDecls(DDA);
    comptime std.testing.refAllDecls(KBI);
    comptime std.testing.refAllDecls(meta);
    comptime std.testing.refAllDecls(cb);
    comptime std.testing.refAllDecls(dtors);
    comptime std.testing.refAllDecls(mt);
    comptime std.testing.refAllDecls(CLikeAllocator);
}
