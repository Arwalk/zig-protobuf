//! Which messages can hold a cycle, known at compile time from their types.

const std = @import("std");

const protobuf = @import("protobuf.zig");
const FieldDescriptor = protobuf.FieldDescriptor;
const evalBranchQuotaFor = protobuf.evalBranchQuotaFor;

/// The number of buckets `CycleAnalysis` sorts the types it reaches into
/// (see `typeBucket`).
const cycle_buckets: usize = 1024;

/// The most characters of a type name that `typeBucket` hashes.
const hashed_name_len: usize = 16;

/// The bucket of the type `T`: a hash of the end of its name, where generated
/// names differ, and of its length, modulo `cycle_buckets`. `CycleAnalysis`
/// looks a type up among the types of its bucket only: looking it up among
/// all the types reached made the analysis of each root grow with the square
/// of their number. Types may share a bucket, where comparing the types tells
/// them apart.
fn typeBucket(comptime T: type) usize {
    comptime {
        const name = @typeName(T);
        const end = name[name.len -| hashed_name_len..];
        return (std.hash.Fnv1a_32.hash(end) +% name.len) % cycle_buckets;
    }
}

/// Which of the messages reachable from the message `Root` can lead to a
/// cycle, from their `_desc_table`s.
///
/// The type graph has an edge from a message to each message its fields hold:
/// singular, oneof member, or element of a repeated field (maps included). A
/// pointer edge holds it through `*M` or `?*M`. A cycle in the data follows a
/// loop of types, and needs a pointer on it, as no message can hold itself by
/// value. The loops counted are those with a pointer edge on them, not those
/// through repeated fields and fields held by value only, whose lists point to
/// their elements but are left unchecked. A search for cycles in a `Root` only has to follow the
/// fields holding the types that lead into such a loop.
///
/// The analysis is a work list, as a recursion over types does not terminate
/// on recursive ones. It runs once per `Root`, in the container-level
/// constants below: each is evaluated on its own, with its own count of
/// branches, so neither callers nor the other constants pay for it. One
/// analysis answers for all the types `Root` reaches: one for each of them
/// would make the cost grow with the square of their number.
fn CycleAnalysis(comptime Root: type) type {
    return struct {
        /// Whether a `Root` can hold a cycle. Most messages hold no other,
        /// and need no graph.
        const can_cycle: bool = can_cycle: {
            @setEvalBranchQuota(evalBranchQuotaFor(Root));
            break :can_cycle heldMessages(Root).len > 0 and leads_into_loop[0];
        };

        /// An edge of the type graph, to the index of a type in `graph.types`.
        const Edge = struct { to: usize, held: HeldMessage };

        /// The types reachable from `Root` (`Root` at index 0), the edges from
        /// each, and their number.
        const graph = graph: {
            var types: []const type = &.{Root};
            var edges: []const []const Edge = &.{};
            var edge_count: usize = 0;
            // Each message held is compared with the types reached before
            // it in its bucket. The quota covers the worst case, all of
            // them in one bucket, and the hash of each name.
            var buckets: [cycle_buckets][]const usize = @splat(&.{});
            buckets[typeBucket(Root)] = &.{0};
            var quota: usize = 0;
            var i: usize = 0;
            while (i < types.len) : (i += 1) {
                quota += evalBranchQuotaFor(types[i]);
                @setEvalBranchQuota(quota);
                const held = heldMessages(types[i]);
                quota += held.len * (types.len + held.len + hashed_name_len);
                @setEvalBranchQuota(quota);
                var out: []const Edge = &.{};
                for (held) |h| {
                    const b = typeBucket(h.Message);
                    const to = for (buckets[b]) |j| {
                        if (types[j] == h.Message) break j;
                    } else new: {
                        types = types ++ .{h.Message};
                        buckets[b] = buckets[b] ++ .{types.len - 1};
                        break :new types.len - 1;
                    };
                    out = out ++ .{Edge{ .to = to, .held = h }};
                }
                edges = edges ++ .{out};
                edge_count += out.len;
            }
            break :graph .{ .types = types, .edges = edges, .edge_count = edge_count };
        };

        /// Whether each type of `graph` leads into a loop with a pointer edge,
        /// or is on one: whether it can hold a cycle.
        ///
        /// Tarjan's algorithm: a depth-first search from `Root`, which reaches
        /// every type, finds the strongly connected components, each after
        /// those it leads to. A pointer edge is on a loop when both its ends
        /// are in one component.
        const leads_into_loop: [graph.types.len]bool = leads: {
            // Each edge is followed once and each type finished once; then the
            // types of each component are found, and their edges followed.
            @setEvalBranchQuota(evalBranchQuotaFor(Root) + 4 * (graph.types.len + graph.edge_count));
            const edges = graph.edges;
            var result: [graph.types.len]bool = @splat(false);
            // When each type was reached, from 1 (0: not yet), and the
            // earliest type of its component that it leads to so far.
            var order: [graph.types.len]usize = @splat(0);
            var low: [graph.types.len]usize = undefined;
            // Whether the component of each type is complete.
            var complete: [graph.types.len]bool = @splat(false);
            // The path of the search, the next edge to follow from each type,
            // and the types reached whose component is not complete.
            var path: [graph.types.len]usize = undefined;
            var next_edge: [graph.types.len]usize = @splat(0);
            var open: [graph.types.len]usize = undefined;
            path[0] = 0;
            open[0] = 0;
            order[0] = 1;
            low[0] = 1;
            var reached: usize = 1;
            var open_len: usize = 1;
            var depth: usize = 1;
            while (depth > 0) {
                const t = path[depth - 1];
                if (next_edge[t] < edges[t].len) {
                    const to = edges[t][next_edge[t]].to;
                    next_edge[t] += 1;
                    if (order[to] == 0) {
                        reached += 1;
                        order[to] = reached;
                        low[to] = reached;
                        path[depth] = to;
                        depth += 1;
                        open[open_len] = to;
                        open_len += 1;
                    } else if (!complete[to]) {
                        low[t] = @min(low[t], order[to]);
                    }
                    continue;
                }
                depth -= 1;
                if (depth > 0) low[path[depth - 1]] = @min(low[path[depth - 1]], low[t]);
                if (low[t] != order[t]) continue;
                // `t` and the types opened after it are a component: the edges
                // leaving it lead to complete ones.
                var first = open_len - 1;
                while (open[first] != t) first -= 1;
                const members = open[first..open_len];
                open_len = first;
                var leads = false;
                for (members) |m| for (edges[m]) |edge| {
                    if (if (complete[edge.to]) result[edge.to] else edge.held.kind == .pointer) leads = true;
                };
                for (members) |m| {
                    complete[m] = true;
                    result[m] = leads;
                }
            }
            break :leads result;
        };
    };
}

/// A field of a message that holds other messages, or a oneof member that
/// does.
pub const HeldMessage = struct {
    /// The type of the messages held.
    Message: type,
    /// The field, and the member when the field is a oneof.
    field: []const u8,
    member: ?[]const u8 = null,
    /// How the field or member holds them: one by value (`M` or `?M`), one
    /// through a pointer (`*M` or `?*M`), or those of a list.
    kind: enum { value, pointer, repeated },
};

/// The messages held by the fields of the message `M`: singular submessages,
/// oneof members, and elements of repeated fields (maps included). Fields
/// missing from `_desc_table`, as `_unknown_fields` or `_extensions`, hold
/// none.
pub fn heldMessages(comptime M: type) []const HeldMessage {
    comptime {
        var held: []const HeldMessage = &.{};
        for (@typeInfo(@TypeOf(M._desc_table)).@"struct".field_names) |name| {
            const desc: FieldDescriptor = @field(M._desc_table, name);
            switch (desc.ftype) {
                .submessage => held = held ++ .{heldBy(@FieldType(M, name), name, null)},
                .repeated => |r| if (r == .submessage) {
                    const Element = @typeInfo(@FieldType(@FieldType(M, name), "items")).pointer.child;
                    held = held ++ .{HeldMessage{ .Message = Element, .field = name, .kind = .repeated }};
                },
                .oneof => |OneOf| for (@typeInfo(@TypeOf(OneOf._desc_table)).@"struct".field_names) |member| {
                    const member_desc: FieldDescriptor = @field(OneOf._desc_table, member);
                    if (member_desc.ftype == .submessage) {
                        held = held ++ .{heldBy(@FieldType(OneOf, member), name, member)};
                    }
                },
                else => {},
            }
        }
        return held;
    }
}

/// The message held by a singular field or a oneof member of type `F`.
fn heldBy(comptime F: type, comptime field: []const u8, comptime member: ?[]const u8) HeldMessage {
    const Held = switch (@typeInfo(F)) {
        .optional => |o| o.child,
        else => F,
    };
    return .{
        .Message = MessageOf(Held),
        .field = field,
        .member = member,
        .kind = if (@typeInfo(Held) == .pointer) .pointer else .value,
    };
}

/// The message type behind a field of type `M`, `?M`, `*M` or `?*M`.
pub fn MessageOf(comptime F: type) type {
    return switch (@typeInfo(F)) {
        .optional => |o| MessageOf(o.child),
        .pointer => |p| p.child,
        else => F,
    };
}

const fd = protobuf.fd;

/// Hand-written messages for the cycle tests: the shapes of type graph that
/// can, or cannot, hold a cycle.
const cycle_test = struct {
    const Plain = struct {
        a: ?i32 = null,
        pub const _desc_table = .{ .a = fd(1, .{ .scalar = .int32 }) };
    };
    const SelfPtr = struct {
        next: ?*@This() = null,
        pub const _desc_table = .{ .next = fd(1, .submessage) };
    };
    const MutualA = struct {
        b: ?*MutualB = null,
        pub const _desc_table = .{ .b = fd(1, .submessage) };
    };
    const MutualB = struct {
        choice: ?Choice = null,
        pub const Choice = union(enum) {
            a: *MutualA,
            leaf: i32,
            pub const _desc_table = .{ .a = fd(1, .submessage), .leaf = fd(2, .{ .scalar = .int32 }) };
        };
        pub const _desc_table = .{ .choice = fd(null, .{ .oneof = Choice }) };
    };
    /// `Inner` points to `Enclosing`, which holds no `Inner`.
    const Enclosing = struct {
        x: ?i32 = null,
        pub const _desc_table = .{ .x = fd(1, .{ .scalar = .int32 }) };
        pub const Inner = struct {
            up: ?*Enclosing = null,
            pub const _desc_table = .{ .up = fd(1, .submessage) };
        };
    };
    /// Recursion through a list only: not checked.
    const ListA = struct {
        arr: ?ListB = null,
        pub const _desc_table = .{ .arr = fd(1, .submessage) };
    };
    const ListB = struct {
        values: std.ArrayList(ListA) = .empty,
        pub const _desc_table = .{ .values = fd(1, .{ .repeated = .submessage }) };
    };
    /// Leads into `SelfPtr`, which can cycle, and holds `Plain`, which cannot.
    const Holder = struct {
        inner: ?SelfPtr = null,
        plain: ?Plain = null,
        pub const _desc_table = .{ .inner = fd(1, .submessage), .plain = fd(2, .submessage) };
    };
    /// A loop with a by-value edge and a pointer edge. Its only field holds
    /// a `ByValueInner` by value, at its own address.
    const ByValue = struct {
        inner: ?ByValueInner = null,
        pub const _desc_table = .{ .inner = fd(1, .submessage) };
    };
    const ByValueInner = struct {
        back: ?*ByValue = null,
        pub const _desc_table = .{ .back = fd(1, .submessage) };
    };
    /// A loop with a pointer edge and a repeated edge.
    const PtrListA = struct {
        b: ?*PtrListB = null,
        pub const _desc_table = .{ .b = fd(1, .submessage) };
    };
    const PtrListB = struct {
        values: std.ArrayList(PtrListA) = .empty,
        pub const _desc_table = .{ .values = fd(1, .{ .repeated = .submessage }) };
    };
    /// Points to `Plain`, which cannot cycle, and holds `PtrListA` by value,
    /// which can.
    const LeafAndLoop = struct {
        leaf: ?*Plain = null,
        loop: ?PtrListA = null,
        pub const _desc_table = .{ .leaf = fd(1, .submessage), .loop = fd(2, .submessage) };
    };
    /// A loop through a by-value edge and a repeated edge, whose only
    /// pointer leaves it for `Plain`, which has no way back.
    const EscapeA = struct {
        b: ?EscapeB = null,
        pub const _desc_table = .{ .b = fd(1, .submessage) };
    };
    const EscapeB = struct {
        values: std.ArrayList(EscapeA) = .empty,
        out: ?*Plain = null,
        pub const _desc_table = .{ .values = fd(1, .{ .repeated = .submessage }), .out = fd(2, .submessage) };
    };
    /// A loop of three types, whose only pointer edge is the first one.
    const FirstPtrA = struct {
        b: ?*FirstPtrB = null,
        pub const _desc_table = .{ .b = fd(1, .submessage) };
    };
    const FirstPtrB = struct {
        c: ?FirstPtrC = null,
        pub const _desc_table = .{ .c = fd(1, .submessage) };
    };
    const FirstPtrC = struct {
        as: std.ArrayList(FirstPtrA) = .empty,
        pub const _desc_table = .{ .as = fd(1, .{ .repeated = .submessage }) };
    };
    /// Pointers that meet again, without a loop.
    const Meeting = struct {
        end: ?*Plain = null,
        way: ?*MeetingWay = null,
        pub const _desc_table = .{ .end = fd(1, .submessage), .way = fd(2, .submessage) };
    };
    const MeetingWay = struct {
        end: ?*Plain = null,
        pub const _desc_table = .{ .end = fd(1, .submessage) };
    };
    /// Can cycle through `next`, but not through `list`.
    const PtrAndList = struct {
        next: ?*PtrAndList = null,
        list: ?ListA = null,
        pub const _desc_table = .{ .next = fd(1, .submessage), .list = fd(2, .submessage) };
    };
    /// Distinct message types in a binary tree `depth` levels deep: left children
    /// by value, right ones in lists, and leaves pointing back to `Root`.
    fn GraphNode(comptime Root: type, comptime depth: u32, comptime index: u32) type {
        if (depth == 0) return struct {
            back: ?*Root = null,
            // Captures `index`: Zig merges identical structs that capture nothing.
            pub const leaf_index = index;
            pub const _desc_table = .{ .back = fd(1, .submessage) };
        };
        return struct {
            left: ?GraphNode(Root, depth - 1, 2 * index) = null,
            right: std.ArrayList(GraphNode(Root, depth - 1, 2 * index + 1)) = .empty,
            pub const _desc_table = .{ .left = fd(1, .submessage), .right = fd(2, .{ .repeated = .submessage }) };
        };
    }
    const BigRoot = struct {
        tree: ?GraphNode(BigRoot, 8, 0) = null,
        pub const _desc_table = .{ .tree = fd(1, .submessage) };
    };
};

fn canCycle(comptime M: type) bool {
    return CycleAnalysis(M).can_cycle;
}

/// Whether a search for cycles in a `Root` follows the fields holding an `M`.
fn follows(comptime Root: type, comptime M: type) bool {
    const A = CycleAnalysis(Root);
    return comptime A.leads_into_loop[std.mem.findScalar(type, A.graph.types, M).?];
}

test "cycle analysis: which messages can hold a cycle" {
    const t = cycle_test;
    try std.testing.expect(!canCycle(t.Plain));
    try std.testing.expect(canCycle(t.SelfPtr));
    try std.testing.expect(canCycle(t.MutualA) and canCycle(t.MutualB));
    try std.testing.expect(!canCycle(t.Enclosing) and !canCycle(t.Enclosing.Inner));
    try std.testing.expect(!canCycle(t.ListA) and !canCycle(t.ListB));
    try std.testing.expect(canCycle(t.Holder));
    try std.testing.expect(follows(t.Holder, t.Holder) and follows(t.Holder, t.SelfPtr));
    try std.testing.expect(!follows(t.Holder, t.Plain));
    try std.testing.expect(canCycle(t.ByValue) and canCycle(t.ByValueInner));
    try std.testing.expect(canCycle(t.PtrListA) and canCycle(t.PtrListB));
    try std.testing.expect(follows(t.LeafAndLoop, t.PtrListA) and follows(t.LeafAndLoop, t.PtrListB));
    try std.testing.expect(!follows(t.LeafAndLoop, t.Plain));
    try std.testing.expect(!canCycle(t.EscapeA) and !canCycle(t.EscapeB));
    try std.testing.expect(canCycle(t.FirstPtrA) and canCycle(t.FirstPtrB) and canCycle(t.FirstPtrC));
    try std.testing.expect(!canCycle(t.Meeting) and !canCycle(t.MeetingWay));
    try std.testing.expect(follows(t.PtrAndList, t.PtrAndList) and !follows(t.PtrAndList, t.ListA));
}

test "cycle analysis: a large graph with pointers back to its root" {
    try std.testing.expect(canCycle(cycle_test.BigRoot));
    const leads = CycleAnalysis(cycle_test.BigRoot).leads_into_loop;
    try std.testing.expectEqual(512, std.mem.countScalar(bool, &leads, true));
}
