const std = @import("std");

pub const Cell = packed struct {
    const Type = enum(u2) {
        air,
        liquid,
        powder,
        solid,
    };

    const Weight = u2;
    const Subtype = u3;
    const Property = u4;

    type: Type,
    weight: Weight,
    subtype: Subtype,
    has_bkg: bool,
    property_1: Property = 0,
    property_2: Property = 0,

    pub fn asU16(self: @This()) u16 {
        return @bitCast(self);
    }

    pub fn fromU16(value: u16) @This() {
        return @bitCast(value);
    }

    pub fn swap(a: *@This(), b: *@This()) void {
        const a_to_b = @This(){
            .type = b.type,
            .weight = b.weight,
            .subtype = b.subtype,
            .property_1 = b.property_1,
            .property_2 = b.property_2,
            .has_bkg = a.has_bkg,
        };

        const b_to_a = @This(){
            .type = a.type,
            .weight = a.weight,
            .subtype = a.subtype,
            .property_1 = a.property_1,
            .property_2 = a.property_2,
            .has_bkg = b.has_bkg,
        };

        a.* = a_to_b;
        b.* = b_to_a;
    }

    pub fn propagateProperty(a: *@This(), b: *@This()) void {
        if (a.property_1 > b.property_1) {
            a.property_1 -= 1;
            b.property_2 += 1;
        } else if (a.property_1 > b.property_1) {
            a.property_1 += 1;
            b.property_2 -= 1;
        }
    }
};

test "Cell:is_one_byte" {
    comptime try std.testing.expectEqual(2, @sizeOf(Cell));
    comptime try std.testing.expectEqual(16, @bitSizeOf(Cell));
}

pub const cell_types = struct {
    pub const air = Cell{ .type = .air, .weight = 0, .subtype = 0, .has_bkg = false };
    pub const bkg = Cell{ .type = .air, .weight = 0, .subtype = 0, .has_bkg = true };
    pub const soil = Cell{ .type = .solid, .weight = 0, .subtype = 0, .has_bkg = true };
    pub const soil_nb = Cell{ .type = .solid, .weight = 0, .subtype = 0, .has_bkg = false };
    pub const gold = Cell{ .type = .solid, .weight = 1, .subtype = 1, .has_bkg = true };
    pub const gold_nb = Cell{ .type = .solid, .weight = 1, .subtype = 1, .has_bkg = false };
    pub const rock = Cell{ .type = .solid, .weight = 1, .subtype = 2, .has_bkg = true };
    pub const rock_nb = Cell{ .type = .solid, .weight = 1, .subtype = 2, .has_bkg = false };
    pub const water = Cell{ .type = .liquid, .weight = 1, .subtype = 0, .has_bkg = true };
    pub const water_nb = Cell{ .type = .liquid, .weight = 1, .subtype = 0, .has_bkg = false };
    pub const acid = Cell{ .type = .liquid, .weight = 1, .subtype = 1, .has_bkg = true };
    pub const acid_nb = Cell{ .type = .liquid, .weight = 1, .subtype = 1, .has_bkg = false };
    pub const sand = Cell{ .type = .powder, .weight = 1, .subtype = 0, .has_bkg = true };
    pub const sand_nb = Cell{ .type = .powder, .weight = 1, .subtype = 0, .has_bkg = false };
};
