const std = @import("std");
const id_containers = @import("id_containers.zig");

pub const IdArray = id_containers.IdArray;
pub const ExtIdMappedIdArray = id_containers.ExtIdMappedIdArray;

pub const DDA = @import("DDA.zig");
pub const KBI = @import("KBI.zig");
pub const integrators = @import("integrators.zig");
pub const meta = @import("meta.zig");
pub const cb = @import("cb.zig");

pub fn panicOnError(retVal: anytype) @typeInfo(@TypeOf(retVal)).ErrorUnion.payload {
    return retVal catch @panic("Panic on error");
}

test {
    comptime std.testing.refAllDecls(id_containers);
    comptime std.testing.refAllDecls(DDA);
    comptime std.testing.refAllDecls(KBI);
    comptime std.testing.refAllDecls(meta);
    comptime std.testing.refAllDecls(cb);
}
