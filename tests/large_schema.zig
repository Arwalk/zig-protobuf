//! Large real schemas must compile: the comptime work done for a message,
//! and the eval branch quota it gets, must not grow with the number of paths
//! to the messages it reaches.
const std = @import("std");
const testing = std.testing;
const services = @import("./.generated/googleads/google/ads/googleads/v26/services.pb.zig");

// The Google Ads API search response reaches 735 message types, which share
// many submessages (tests/protos_for_test/googleads): counting fields along
// every path through them comes to 58,506.
test "large schema: the Google Ads search response" {
    const gpa = testing.allocator;
    const Response = services.SearchGoogleAdsResponse;
    // results { campaign { resource_name: "customers/1/campaigns/7" id: 7 name: "c" } }
    // total_results_count: 1
    const campaign = "\x0a\x17customers/1/campaigns/7" ++ "\xd8\x03\x07" ++ "\xd2\x03\x01c";
    const row = "\x12" ++ .{campaign.len} ++ campaign;
    const bytes = "\x0a" ++ .{row.len} ++ row ++ "\x18\x01";

    var reader: std.Io.Reader = .fixed(bytes);
    var msg = try Response.decode(&reader, gpa);
    defer msg.deinit(gpa);
    try expectCampaign(msg);

    var w: std.Io.Writer.Allocating = .init(gpa);
    defer w.deinit();
    try msg.encode(&w.writer, gpa);
    var again_reader: std.Io.Reader = .fixed(w.written());
    var again = try Response.decode(&again_reader, gpa);
    defer again.deinit(gpa);
    try expectCampaign(again);

    var copy = try msg.dupe(gpa);
    defer copy.deinit(gpa);
    try expectCampaign(copy);
}

fn expectCampaign(msg: services.SearchGoogleAdsResponse) !void {
    try testing.expectEqual(1, msg.total_results_count);
    try testing.expectEqual(1, msg.results.items.len);
    const campaign = msg.results.items[0].campaign.?;
    try testing.expectEqualStrings("customers/1/campaigns/7", campaign.resource_name);
    try testing.expectEqual(7, campaign.id);
    try testing.expectEqualStrings("c", campaign.name.?);
}
