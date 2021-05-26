const std = @import("std");
const isSignedInt = std.meta.trait.isSignedInt;

// common definitions

const ArrayList = std.ArrayList;

const VarintType = enum {
    Simple,
    ZigZagOptimized
};

pub const FieldTypeTag = enum{
    Varint,
    FixedInt,
    SubMessage,
    List,
};

pub const ListTypeTag = enum {
    Varint,
    FixedInt,
    SubMessage,
};

pub const ListType = union(ListTypeTag) {
    Varint : VarintType,
    FixedInt,
    SubMessage,
};

pub const FieldType = union(FieldTypeTag) {
    Varint : VarintType,
    FixedInt,
    SubMessage,
    List : ListType,

    pub fn get_wirevalue(ftype : FieldType, comptime value_type: type) u3 {
        return switch (ftype) {
            .Varint => 0,
            .FixedInt => return switch(@bitSizeOf(value_type)) {
                64 => 1,
                32 => 5,
                else => @panic("Invalid size for fixed int")
            },
            .SubMessage, .List => 2,            
        };
    }
};

pub const FieldDescriptor = struct {
    tag: u32,
    name: comptime []const u8,
    ftype: FieldType,
};

pub fn fd(tag: u32, name: []const u8, ftype: FieldType) FieldDescriptor {
    return FieldDescriptor{
        .tag = tag,
        .name = name,
        .ftype = ftype
    };
}

// encoding

fn encode_varint(pb: *ArrayList(u8), value: anytype) !void {
    var copy = value;
    while(copy != 0) {
        try pb.append(0x80 + @intCast(u8, copy & 0x7F));
        copy = copy >> 7;
    }
    pb.items[pb.items.len - 1] = pb.items[pb.items.len - 1] & 0x7F;
}

fn insert_size_as_varint(pb: *ArrayList(u8), size: u64, start_index: usize) !void {
    if(size < 0x7F){
        try pb.insert(start_index, @truncate(u8, size));
    }
    else
    {
        var copy = size;
        var index = start_index;
        while(copy != 0) : (index += 1 ) {
            try pb.insert(index, 0x80 + @intCast(u8, copy & 0x7F));
            copy = copy >> 7;
        }
        pb.items[pb.items.len - 1] = pb.items[pb.items.len - 1] & 0x7F;
    }
}

fn append_as_varint(pb: *ArrayList(u8), value: anytype, comptime varint_type: VarintType) !void {
    if(value < 0x7F and value >= 0){
        try pb.append(@intCast(u8, value));
    }
    else
    {
        const type_of_val = @TypeOf(value);
        const bitsize = @bitSizeOf(type_of_val);
        const val : u64 = comptime blk: {
            if(isSignedInt(type_of_val)){
                switch(varint_type) {
                    .ZigZagOptimized => {
                        break :blk @intCast(u64, (value >> (bitsize-1)) ^ (value << 1));
                    },
                    .Simple => {
                        break :blk @ptrCast(*const std.meta.Int(.unsigned, bitsize), &value).*;
                    }
                }
            }
            else
            {
                break :blk @intCast(u64, value);
            }   
        };

        try encode_varint(pb, val);
    }
}

fn append_varint(pb : *ArrayList(u8), value: anytype, comptime varint_type: VarintType) !void {
    switch(@typeInfo(@TypeOf(value))) {
        .Enum => try append_as_varint(pb, @as(i32, @enumToInt(value)), varint_type),
        .Bool => try append_as_varint(pb, @as(u8, @boolToInt(value)), varint_type),
        else => try append_as_varint(pb, value, varint_type),
    }
}

fn append_fixed(pb : *ArrayList(u8), value: anytype) !void {
    var copy = value;
    const bitsize = @bitSizeOf(@TypeOf(value));
    var as_unsigned_int = @bitCast(std.meta.Int(.unsigned, bitsize), copy);

    var index : usize = 0;

    while(index < (bitsize/8)) : (index += 1) {
        try pb.append(@truncate(u8, as_unsigned_int));
        as_unsigned_int = as_unsigned_int >> 8;
    }
}

fn append_submessage(pb :* ArrayList(u8), value: anytype) !void {
    const len_index = pb.items.len;
    try internal_pb_encode(pb, value);
    const size_encoded = pb.items.len - len_index;
    try insert_size_as_varint(pb, size_encoded, len_index);
}

fn append_bytes(pb: *ArrayList(u8), value: *const ArrayList(u8)) !void {
    const len_index = pb.items.len;
    try pb.appendSlice(value.items);
    const size_encoded = pb.items.len - len_index;
    try insert_size_as_varint(pb, size_encoded, len_index);
}

fn append_list_of_fixed(pb: *ArrayList(u8), value: anytype) !void {
    const len_index = pb.items.len;
    if(@TypeOf(value) == ArrayList(u8)) {
        try pb.appendSlice(value.items);
    }
    else {
        for(value.items) |item| {
            try append_fixed(pb, item);
        }
    }
    const size_encoded = pb.items.len - len_index;
    try insert_size_as_varint(pb, size_encoded, len_index);
}

fn append_list_of_varint(pb : *ArrayList(u8), value_list: anytype, comptime varint_type: VarintType) !void {
    const len_index = pb.items.len;
    for(value_list.items) |item| {
        try append_varint(pb, item, varint_type);
    }
    const size_encoded = pb.items.len - len_index;
    try insert_size_as_varint(pb, size_encoded, len_index);
}

fn append_list_of_submessages(pb: *ArrayList(u8), value_list: anytype) !void {
    const len_index = pb.items.len;
    for(value_list.items) |item| {
        try append_submessage(pb, item);
    }
    const size_encoded = pb.items.len - len_index;
    try insert_size_as_varint(pb, size_encoded, len_index);
}

fn append_tag(pb : *ArrayList(u8), comptime field: FieldDescriptor,  value_type: type) !void {
    try append_varint(pb, ((field.tag << 3) | field.ftype.get_wirevalue(value_type)), .Simple);
}

fn append(pb : *ArrayList(u8), comptime field: FieldDescriptor, value_type: type, value: anytype) !void {
    try append_tag(pb, field, value_type);
    switch(field.ftype)
    {
        .Varint => |varint_type| {
            try append_varint(pb, value, varint_type);
        },
        .FixedInt => {
            try append_fixed(pb, value);  
        },
        .SubMessage => {
            try append_submessage(pb, value);
        },
        .List => |list_type| {
            switch(list_type) {
                .FixedInt => {
                    try append_list_of_fixed(pb, value);
                },
                .SubMessage => {
                    try append_list_of_submessages(pb, value);
                },
                .Varint => |varint_type| {
                    try append_list_of_varint(pb, value, varint_type);
                }
            }
        }
    }
}

fn internal_pb_encode(pb : *ArrayList(u8), data: anytype) !void {
    const field_list  = @TypeOf(data)._desc_table;

    inline for(field_list) |field| {
        if (@typeInfo(@TypeOf(@field(data, field.name))) == .Optional){
            if(@field(data, field.name)) |value| {
                try append(pb, field, @TypeOf(value), value);
            }
        }
        else
        {
            if(@field(data, field.name).items.len != 0){
                try append(pb, field, @TypeOf(@field(data, field.name)), @field(data, field.name));
            }
        }
    }
}

pub fn pb_encode(data : anytype, allocator: *std.mem.Allocator) ![]u8 {
    var pb = ArrayList(u8).init(allocator);
    errdefer pb.deinit();

    try internal_pb_encode(&pb, data);
    
    return pb.toOwnedSlice();
}

fn get_struct_field(comptime T: type, comptime field_name: []const u8 ) std.builtin.TypeInfo.StructField {
    return inline for (@typeInfo(T).Struct.fields) |field| {
        if(std.mem.eql(u8, field.name, field_name)) {
            break field;
        }
    } else @compileLog("Could not find field ", field_name, " in struct", T);
}

pub fn pb_init(comptime T: type, allocator : *std.mem.Allocator) T {

    comptime {
        if(@typeInfo(T).Struct.fields.len != T._desc_table.len) {
            @compileLog("malformed structure or desc table for structure", T);
            @compileLog("@typeInfo(T).Struct.fields.len =", @typeInfo(T).Struct.fields.len);
            @compileLog("T._desc_table.len =", T._desc_table.len);
        }
    }

    var value: T = undefined;

    inline for (T._desc_table) |field| {
        switch (field.ftype) {
            .Varint, .FixedInt => {
                const struct_field = get_struct_field(T, field.name);
                @field(value, field.name) = if(struct_field.default_value) |val| val else null;
            },
            .SubMessage, .List => {
                @field(value, field.name) = @TypeOf(@field(value, field.name)).init(allocator);
            },
        }
    }

    return value;
}

pub fn pb_deinit(data: anytype) void {
    const field_list  = @TypeOf(data)._desc_table;

    inline for(field_list) |field| {
        switch (field.ftype) {
            .Varint, .FixedInt => {},
            .SubMessage => {
                @field(data, field.name).deinit();
            },
            .List => |list_type| {
                if(list_type == .SubMessage) {
                    for(@field(data, field.name).items) |item| {
                        item.deinit();
                    }
                }
                @field(data, field.name).deinit();
            }
        }
    }
}

// decoding

const ExtractedDataTag = enum {
    RawValue,
    Slice,
};

const ExtractedData = union(ExtractedDataTag) {
    RawValue : u64,
    Slice: []const u8
};

const Extracted = struct {
    tag: u32,
    data: ExtractedData
};

fn DecodedVarint(comptime T: type) type {
    return struct {
        value: T,
        size: usize,
    };
}

fn decode_varint(comptime T: type, input: []const u8) DecodedVarint(T) {
    var value: T = 0;
    var index: usize = 0;

    while((input[index] & 0b10000000) != 0) : (index += 1) {
        value += (@as(T, input[index] & 0x7F)) << (@intCast(std.math.Log2Int(T), index*7));
    }

    value += (@as(T, input[index] & 0x7F)) << (@intCast(std.math.Log2Int(T), index*7));

    return DecodedVarint(T){
        .value = value,
        .size = index +1,
    };
}

const WireDecoderIterator = struct {
    input: []const u8,
    current_index : usize = 0,
    
    fn next(state: *WireDecoderIterator) !?Extracted {
        if(state.current_index < state.input.len) {
            const tag_and_wire = decode_varint(u32, state.input[state.current_index..]);
            state.current_index += tag_and_wire.size;
            const tag : u32 = (tag_and_wire.value >> 3);
            const wire_value = tag_and_wire.value & 0b00000111;
            const data : ExtractedData = switch(wire_value) {
                0 => blk: {
                    const varint = decode_varint(u64, state.input[state.current_index..]);
                    state.current_index += varint.size;
                    break :blk ExtractedData{
                        .RawValue = varint.value,
                    };
                },
                else => @panic("Not implemented yet")
            };

            return Extracted{
                .tag = tag,
                .data = data
            };
        }
        else
        {
            return null;
        }    
    }
};

fn get_descriptor(comptime fields : []const FieldDescriptor, tag: u32) ?comptime *const FieldDescriptor {
    return inline for(fields) |*desc| {
        if(desc.tag == tag) break desc;
    } else null;
}

const FullFieldDescriptor = struct {
    field_name: []const u8,
    tag: u32,
    pb_type: FieldType,
    real_type: type
};

fn get_varint_value(comptime T : type, comptime varint_type : VarintType, extracted_data: Extracted) T {
    return comptime switch(varint_type) {
        .ZigZagOptimized => 
            switch (@typeInfo(T)) {
                .Int =>  @intCast(T, (@intCast(i64, extracted_data.data.RawValue) >> 1) ^ (-(@intCast(i64, extracted_data.data.RawValue) & 1))),
                .Enum => @intToEnum(T, @intCast(i32, (@intCast(i64, extracted_data.data.RawValue) >> 1) ^ (-(@intCast(i64, extracted_data.data.RawValue) & 1)))),
                else => unreachable
            }
        ,
        .Simple => 
            switch (@typeInfo(T)) {
                .Int => switch(T) {
                    u32, u64 => @intCast(T, extracted_data.data.RawValue),
                    i32, i64 => @bitCast(T, @truncate(std.meta.Int(.unsigned, @bitSizeOf(T)), extracted_data.data.RawValue)),
                    else => unreachable
                },
                .Bool => extracted_data.data.RawValue == 1,
                .Enum => @intToEnum(T, @intCast(i32, extracted_data.data.RawValue)),
                else => unreachable
            }
    };
}

pub fn pb_decode(comptime T: type, input: []const u8, allocator: *std.mem.Allocator) !T {
    var result = pb_init(T, allocator);
    
    var iterator = WireDecoderIterator{.input = input};

    comptime const field_lists = blk: {
        comptime var fields : [T._desc_table.len]FullFieldDescriptor = [_]FullFieldDescriptor{
            .{
                .field_name = "",
                .tag = 0,
                .pb_type = .FixedInt,
                .real_type = bool,
            }
        } ** T._desc_table.len;

        inline for (T._desc_table) |field, index| {
            const real_field = get_struct_field(T, field.name);
            fields[index].field_name = field.name;
            fields[index].tag = field.tag;
            fields[index].pb_type = field.ftype;
            fields[index].real_type = real_field.field_type;
        }

        break :blk fields;
    };

    while(try iterator.next()) |extracted_data| {
        
        const field_found : ?*const FullFieldDescriptor = inline for (field_lists) |*field| {
            if(field.tag == extracted_data.tag) break field;
        } else null;

        if(field_found) |field| {
            const child_type = @typeInfo(field.real_type).Optional.child;
            
            @field(result, field.field_name) = switch(field.pb_type) {
                .Varint => |varint_type| get_varint_value(child_type, varint_type, extracted_data),
                
                else => @panic("Not implemented")
            };
        }
    }

    return result;
}

// TBD

// tests

const testing = std.testing;

test "get varint" {
    var pb = ArrayList(u8).init(testing.allocator);
    const value: u32 = 300;
    defer pb.deinit();
    try append_varint(&pb, value, .Simple);

    try testing.expectEqualSlices(u8, &[_]u8{0b10101100, 0b00000010}, pb.items);
}

