const math = @import("std").math;
const Value = @import("../../generated/google/protobuf.pb.zig").Value;

pub fn get1() Value {
    return Value{
        .kind = .{
            .number_value = math.nan(f64),
        },
    };
}

pub fn get2() Value {
    return Value{
        .kind = .{
            .number_value = -math.inf(f64),
        },
    };
}

pub fn get3() Value {
    return Value{
        .kind = .{
            .number_value = math.inf(f64),
        },
    };
}

pub fn get4() Value {
    return Value{
        .kind = .{
            .number_value = 1.0,
        },
    };
}
