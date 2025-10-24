const std = @import("std");
const expect = std.testing.expect;
const expectEqualSlices = std.testing.expectEqualSlices;
const allocator = std.testing.allocator;

const protobuf = @import("protobuf");
const pb = @import("generated/tests.pb.zig");

// This test verifies that the fixes for complex types work correctly:
// 1. @setEvalBranchQuota(1000000) in parse() allows types with 100+ fields
//    to compile without hitting the 1000 backwards branches limit
// 2. to_camel_case() creates new string instead of mutating const, which
//    allows fields starting with uppercase (APIVersion, Kind) to work

test "JSON: decode ComplexType with many fields and uppercase field names" {
    // This JSON includes:
    // - Fields starting with uppercase (APIVersion, Kind) which test the to_camel_case fix
    // - 110+ total fields which test the @setEvalBranchQuota fix
    const json_data =
        \\{
        \\  "APIVersion": "v1",
        \\  "Kind": "Pod",
        \\  "field3": "value3",
        \\  "field4": "value4",
        \\  "field5": "value5",
        \\  "field6": "value6",
        \\  "field7": "value7",
        \\  "field8": "value8",
        \\  "field9": "value9",
        \\  "field10": "value10",
        \\  "field11": "value11",
        \\  "field12": "value12",
        \\  "field13": "value13",
        \\  "field14": "value14",
        \\  "field15": "value15",
        \\  "field16": "value16",
        \\  "field17": "value17",
        \\  "field18": "value18",
        \\  "field19": "value19",
        \\  "field20": "value20",
        \\  "field21": "value21",
        \\  "field22": "value22",
        \\  "field23": "value23",
        \\  "field24": "value24",
        \\  "field25": "value25",
        \\  "field26": "value26",
        \\  "field27": "value27",
        \\  "field28": "value28",
        \\  "field29": "value29",
        \\  "field30": "value30",
        \\  "field31": "value31",
        \\  "field32": "value32",
        \\  "field33": "value33",
        \\  "field34": "value34",
        \\  "field35": "value35",
        \\  "field36": "value36",
        \\  "field37": "value37",
        \\  "field38": "value38",
        \\  "field39": "value39",
        \\  "field40": "value40",
        \\  "field41": "value41",
        \\  "field42": "value42",
        \\  "field43": "value43",
        \\  "field44": "value44",
        \\  "field45": "value45",
        \\  "field46": "value46",
        \\  "field47": "value47",
        \\  "field48": "value48",
        \\  "field49": "value49",
        \\  "field50": "value50",
        \\  "field51": "value51",
        \\  "field52": "value52",
        \\  "field53": "value53",
        \\  "field54": "value54",
        \\  "field55": "value55",
        \\  "field56": "value56",
        \\  "field57": "value57",
        \\  "field58": "value58",
        \\  "field59": "value59",
        \\  "field60": "value60",
        \\  "field61": "value61",
        \\  "field62": "value62",
        \\  "field63": "value63",
        \\  "field64": "value64",
        \\  "field65": "value65",
        \\  "field66": "value66",
        \\  "field67": "value67",
        \\  "field68": "value68",
        \\  "field69": "value69",
        \\  "field70": "value70",
        \\  "field71": "value71",
        \\  "field72": "value72",
        \\  "field73": "value73",
        \\  "field74": "value74",
        \\  "field75": "value75",
        \\  "field76": "value76",
        \\  "field77": "value77",
        \\  "field78": "value78",
        \\  "field79": "value79",
        \\  "field80": "value80",
        \\  "field81": "value81",
        \\  "field82": "value82",
        \\  "field83": "value83",
        \\  "field84": "value84",
        \\  "field85": "value85",
        \\  "field86": "value86",
        \\  "field87": "value87",
        \\  "field88": "value88",
        \\  "field89": "value89",
        \\  "field90": "value90",
        \\  "field91": "value91",
        \\  "field92": "value92",
        \\  "field93": "value93",
        \\  "field94": "value94",
        \\  "field95": "value95",
        \\  "field96": "value96",
        \\  "field97": "value97",
        \\  "field98": "value98",
        \\  "field99": "value99",
        \\  "field100": "value100",
        \\  "field101": "value101",
        \\  "field102": "value102",
        \\  "field103": "value103",
        \\  "field104": "value104",
        \\  "field105": "value105",
        \\  "field106": "value106",
        \\  "field107": "value107",
        \\  "field108": "value108",
        \\  "field109": "value109",
        \\  "field110": "value110"
        \\}
    ;

    // Without the fixes, this would fail with:
    // 1. "evaluation exceeded 1000 backwards branches" during compile-time field name comparison
    // 2. "cannot assign to constant" in to_camel_case() when processing "APIVersion" and "Kind"
    const decoded = try pb.ComplexType.jsonDecode(
        json_data,
        .{},
        allocator,
    );
    defer decoded.deinit();

    // Verify that the fields were correctly decoded
    try expectEqualSlices(u8, "v1", decoded.value.APIVersion);
    try expectEqualSlices(u8, "Pod", decoded.value.Kind);
    try expectEqualSlices(u8, "value3", decoded.value.field_3);
    try expectEqualSlices(u8, "value10", decoded.value.field_10);
    try expectEqualSlices(u8, "value50", decoded.value.field_50);
    try expectEqualSlices(u8, "value100", decoded.value.field_100);
    try expectEqualSlices(u8, "value110", decoded.value.field_110);
}

test "JSON: encode ComplexType with many fields" {
    var complex_instance = pb.ComplexType{
        .APIVersion = "v1",
        .Kind = "Pod",
        .field_3 = "value3",
        .field_10 = "value10",
        .field_50 = "value50",
        .field_100 = "value100",
        .field_110 = "value110",
    };

    // Encoding should also work with the fixes in place
    const encoded = try complex_instance.jsonEncode(
        .{ .whitespace = .indent_2 },
        allocator,
    );
    defer allocator.free(encoded);

    // Verify that APIVersion and Kind are correctly encoded
    // (with lowercase first letter in JSON: "aPIVersion", "kind")
    // Note: The to_camel_case function converts snake_case to camelCase
    // APIVersion becomes aPIVersion (first letter lowercased)
    try expect(std.mem.indexOf(u8, encoded, "\"aPIVersion\"") != null);
    try expect(std.mem.indexOf(u8, encoded, "\"kind\"") != null);
}
