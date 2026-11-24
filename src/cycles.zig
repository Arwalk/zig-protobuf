//! Which messages can hold a cycle, known at compile time from their types,
//! and the search for one in a message.

const std = @import("std");
const builtin = @import("builtin");

const protobuf = @import("protobuf.zig");
const FieldDescriptor = protobuf.FieldDescriptor;
const evalBranchQuotaFor = protobuf.evalBranchQuotaFor;

/// Whether the message `msg`, or the message `msg` points to, holds a cycle: a
/// message that leads back to itself through the messages its fields hold,
/// which encoding would follow until the stack overflows.
///
/// The cycles searched for are those of the message types that lead back to
/// themselves through a pointer field. For a message type that leads to none
/// of them, the result is `false` at compile time, and no code runs (see
/// `CycleAnalysis`). Types that lead back to themselves through repeated
/// fields and fields held by value only are not searched for. A message
/// reached twice without looping, as one shared by two fields, is not a cycle:
/// it is searched each time, as it is encoded each time.
///
/// The search takes no more stack for deep messages than for others. It
/// allocates memory, freed before it returns, when many messages wait for
/// others to be searched (see `Walk`). A cycle is found at a depth of up to
/// three times the number of messages on the way to it and around it.
pub inline fn hasCycle(msg: anytype, allocator: std.mem.Allocator) std.mem.Allocator.Error!bool {
    const Root = MessageAt(@TypeOf(msg));
    if (comptime @typeInfo(Root) != .@"struct" or !@hasDecl(Root, "_desc_table")) {
        @compileError("expected a message or a pointer to a message, found " ++ @typeName(@TypeOf(msg)));
    }
    // An inline call counts among the branches of its caller.
    @setEvalBranchQuota(comptime evalBranchQuotaFor(Root));
    if (comptime !CycleAnalysis(Root).can_cycle) return false;
    return searchAt(msg, allocator);
}

/// The message type `T`, or the one that the single-item pointer `T` points to.
fn MessageAt(comptime T: type) type {
    return switch (@typeInfo(T)) {
        .pointer => |p| if (p.size == .one) p.child else T,
        else => T,
    };
}

/// `hasCycle` for a message that can hold a cycle. It is apart because taking
/// the address of `msg` copies it, even in code that does not run.
inline fn searchAt(msg: anytype, allocator: std.mem.Allocator) std.mem.Allocator.Error!bool {
    // A message passed by value is a copy: a cycle back to the original is
    // found one level deeper.
    return search(CycleAnalysis(MessageAt(@TypeOf(msg))), supported_way, messageIn(&msg), allocator);
}

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

/// How a walk goes from a message to the next one: with guaranteed tail calls,
/// or through a loop that makes the calls. Neither takes stack.
const Way = enum { tail_calls, loop };

const supported_way: Way = if (has_tail_calls) .tail_calls else .loop;

/// Whether `.always_tail` calls are supported. Elsewhere, the compiler rejects
/// them, LLVM fails on them (Thumb-1), or LLVM makes ordinary calls instead
/// (s390x): check the assembly before adding an architecture.
const has_tail_calls = builtin.zig_backend == .stage2_llvm and switch (builtin.cpu.arch) {
    .x86, .x86_64, .aarch64, .aarch64_be => true,
    .arm, .armeb, .thumb, .thumbeb => !builtin.cpu.has(.arm, .thumb_mode) or builtin.cpu.has(.arm, .thumb2),
    .riscv32, .riscv64, .loongarch32, .loongarch64, .sparc, .sparc64 => true,
    .wasm32, .wasm64 => builtin.cpu.has(.wasm, .tail_call),
    else => false,
};

/// The state of a walk: the messages that wait for others, and what follows
/// them, to be walked. The last one of the messages that a message holds does
/// not wait, so a list of messages, or a chain of them, needs no memory.
const Walk = struct {
    allocator: std.mem.Allocator,
    /// The next ones to visit last.
    waiting: std.ArrayList(Messages),
    /// With a loop, the messages whose first one is to be visited next.
    next: ?Messages = null,

    /// The messages that wait whose first one is to be visited next, if any.
    /// The ones after it still wait.
    fn take(self: *Walk) ?Messages {
        const items = self.waiting.items;
        if (items.len == 0) return null;
        const last = &items[items.len - 1];
        const taken = last.*;
        if (taken.count > 1) last.advance() else self.waiting.items.len -= 1;
        return taken;
    }
};

/// Messages of one type, next to each other in memory, that a message holds.
const Messages = struct {
    visit: *const Visit,
    first: *const anyopaque,
    count: usize,
    /// The distance in bytes between two of them.
    stride: usize,
    depth: usize,
    anchor: ?*const anyopaque,
    anchor_type: usize,

    /// Leaves the first one out. There is at least another one.
    fn advance(self: *Messages) void {
        self.first = @as([*]const u8, @ptrCast(self.first)) + self.stride;
        self.count -= 1;
    }
};

/// The type of `Visitor.visit`, the same for all types of messages, as a tail
/// call has to be to a function of the type of its caller. Its arguments and
/// its result fit in registers: a result written to memory, as an error union
/// with a payload is, makes LLVM fail to compile the tail call.
const Visit = fn (
    message: *const anyopaque,
    depth: usize,
    anchor: ?*const anyopaque,
    anchor_type: usize,
    walk: *Walk,
) VisitError!void;

const VisitError = error{CyclicMessage} || std.mem.Allocator.Error;

/// Whether the message `root`, of the first type in the graph of the analysis
/// `A`, holds a cycle.
fn search(
    comptime A: type,
    comptime way: Way,
    root: *const A.graph.types[0],
    allocator: std.mem.Allocator,
) std.mem.Allocator.Error!bool {
    // Most messages need no more than the buffer.
    var buffer: [32]Messages = undefined;
    var buffer_first: std.heap.BufferFirstAllocator = .init(std.mem.sliceAsBytes(&buffer), allocator);
    const gpa = buffer_first.allocator();
    var walk: Walk = .{ .allocator = gpa, .waiting = try .initCapacity(gpa, buffer.len) };
    defer walk.waiting.deinit(gpa);

    var next: ?Messages = .{
        .visit = &Visitor(A, way, 0).visit,
        .first = root,
        .count = 1,
        .stride = undefined,
        .depth = 1,
        .anchor = null,
        .anchor_type = undefined,
    };
    while (next) |m| : (next = walk.next) {
        walk.next = null;
        m.visit(m.first, m.depth, m.anchor, m.anchor_type, &walk) catch |err| switch (err) {
            error.CyclicMessage => return true,
            error.OutOfMemory => |e| return e,
        };
    }
    return false;
}

/// The visit of the messages of the type of index `t` in the graph of the
/// analysis `A`.
fn Visitor(comptime A: type, comptime way: Way, comptime t: usize) type {
    return struct {
        const T = A.graph.types[t];

        /// Fails with `error.CyclicMessage` when `message`, a `T` at `depth` on
        /// the path, from 1, is the message `anchor` of the type of index
        /// `anchor_type`, or, with tail calls, when the rest of the walk finds
        /// a cycle. Follows only the fields holding messages that can cycle.
        ///
        /// Brent's algorithm: each message is compared with one message above
        /// it on the path, the anchor, which moves down to the message at each
        /// depth that is a power of two. The path into a cycle repeats itself,
        /// so it meets an anchor set in the cycle once the gap between anchors
        /// is as long as the cycle. Comparing with the whole path takes time
        /// that grows with the square of the depth. A message is told apart by
        /// its address and its type: one held by value first in its parent has
        /// the parent's address.
        fn visit(
            message: *const anyopaque,
            depth: usize,
            anchor: ?*const anyopaque,
            anchor_type: usize,
            walk: *Walk,
        ) VisitError!void {
            @setEvalBranchQuota(comptime evalBranchQuotaFor(T));
            if (message == anchor and t == anchor_type) return error.CyclicMessage;
            const moves = std.math.isPowerOfTwo(depth);
            const msg: *const T = @ptrCast(@alignCast(message));

            // From the last messages held to the first: those found before
            // wait for the ones found after.
            var first: ?Messages = null;
            comptime var i = A.graph.edges[t].len;
            inline while (i > 0) {
                i -= 1;
                const edge = comptime A.graph.edges[t][i];
                if (comptime !A.leads_into_loop[edge.to]) continue;
                const held = heldIn(edge.held, &@field(msg, edge.held.field));
                if (held.len > 0) {
                    if (first) |later| try walk.waiting.append(walk.allocator, later);
                    first = .{
                        .visit = &Visitor(A, way, edge.to).visit,
                        .first = held.ptr,
                        .count = held.len,
                        .stride = @sizeOf(edge.held.Message),
                        .depth = depth + 1,
                        .anchor = if (moves) message else anchor,
                        .anchor_type = if (moves) t else anchor_type,
                    };
                }
            }

            if (first) |messages| if (messages.count > 1) {
                var rest = messages;
                rest.advance();
                try walk.waiting.append(walk.allocator, rest);
            };
            const next = first orelse walk.take() orelse return;
            switch (way) {
                .tail_calls => return @call(.always_tail, next.visit, .{ next.first, next.depth, next.anchor, next.anchor_type, walk }),
                .loop => walk.next = next,
            }
        }
    };
}

/// The messages that `held` describes in the field at `field`: none, one, or
/// those of a list.
fn heldIn(comptime held: HeldMessage, field: anytype) []const held.Message {
    if (held.kind == .repeated) return field.items;
    if (field.*) |*value| {
        const member = held.member orelse return messageIn(value)[0..1];
        if (value.* == @field(std.meta.Tag(@TypeOf(value.*)), member)) return messageIn(&@field(value, member))[0..1];
    }
    return &.{};
}

/// The message in the value of a singular or oneof field, from the address
/// of the value: the value itself (`M`), or the message it points to (`*M`).
fn messageIn(value: anytype) *const MessageOf(@TypeOf(value.*)) {
    return if (comptime @typeInfo(@TypeOf(value.*)) == .pointer) value.* else value;
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
    const Pair = struct {
        left: ?*Pair = null,
        right: ?*Pair = null,
        pub const _desc_table = .{ .left = fd(1, .submessage), .right = fd(2, .submessage) };
    };
    /// Can cycle through `next`, and holds more of itself in a list.
    const ListCycle = struct {
        next: ?*ListCycle = null,
        kids: std.ArrayList(ListCycle) = .empty,
        pub const _desc_table = .{ .next = fd(1, .submessage), .kids = fd(2, .{ .repeated = .submessage }) };
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

/// `message` holds a cycle when `expected`, as found by `hasCycle` and by each
/// way of walking that the target supports.
fn expectCycle(expected: bool, message: anytype) !void {
    const gpa = std.testing.allocator;
    try std.testing.expectEqual(expected, try hasCycle(message, gpa));
    const A = CycleAnalysis(MessageOf(@TypeOf(message)));
    try std.testing.expectEqual(expected, try search(A, .loop, messageIn(&message), gpa));
    if (has_tail_calls) try std.testing.expectEqual(expected, try search(A, .tail_calls, messageIn(&message), gpa));
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

test "hasCycle: a message pointing to itself" {
    var n: cycle_test.SelfPtr = .{};
    n.next = &n;
    try expectCycle(true, &n);
    try expectCycle(true, n);
}

test "hasCycle: acyclic chains, shared and diamond submessages" {
    const t = cycle_test;
    var c: t.SelfPtr = .{};
    var b: t.SelfPtr = .{ .next = &c };
    var a: t.SelfPtr = .{ .next = &b };
    try expectCycle(false, &a);
    try expectCycle(false, a);

    var shared: t.Pair = .{};
    var pair: t.Pair = .{ .left = &shared, .right = &shared };
    try expectCycle(false, &pair);

    var leaf: t.ListCycle = .{};
    var arr: [2]t.ListCycle = .{ .{ .next = &leaf }, .{ .next = &leaf } };
    var diamond: t.ListCycle = .{ .kids = .fromOwnedSlice(&arr) };
    try expectCycle(false, &diamond);
}

test "hasCycle: a cycle through a oneof member" {
    var a: cycle_test.MutualA = .{};
    var b: cycle_test.MutualB = .{};
    a.b = &b;
    b.choice = .{ .a = &a };
    try expectCycle(true, &a);
    try expectCycle(true, &b);
}

test "hasCycle: a cycle through a by-value submessage" {
    var o: cycle_test.ByValue = .{};
    o.inner = .{ .back = &o };
    try expectCycle(true, &o);
}

test "hasCycle: a cycle through a repeated field of a message that can cycle" {
    var arr: [1]cycle_test.ListCycle = .{.{}};
    arr[0].kids = .fromOwnedSlice(&arr);
    try expectCycle(true, &arr[0]);
}

test "hasCycle: a cycle of any length at the end of a path of any length" {
    var nodes: [24]cycle_test.SelfPtr = undefined;
    for (1..nodes.len + 1) |len| {
        for (nodes[0..len], 0..) |*node, i| node.* = .{ .next = if (i + 1 < len) &nodes[i + 1] else null };
        try expectCycle(false, &nodes[0]);
        for (nodes[0..len]) |*back| {
            nodes[len - 1].next = back;
            try expectCycle(true, &nodes[0]);
            try expectCycle(true, nodes[0]);
        }
    }
}

test "hasCycle: random object graphs agree with their reachability" {
    const Pair = cycle_test.Pair;
    var prng: std.Random.DefaultPrng = .init(std.testing.random_seed);
    const rnd = prng.random();
    for (0..5000) |_| {
        var nodes: [9]Pair = undefined;
        // reaches[i][j]: whether `nodes[i]` leads to `nodes[j]`.
        var reaches: [nodes.len][nodes.len]bool = @splat(@splat(false));
        for (&nodes, &reaches, 0..) |*node, *row, i| {
            var held: [2]?*Pair = @splat(null);
            for (&held) |*h| if (rnd.uintLessThan(u8, 3) != 0) {
                // Mostly to the nodes after it, which makes no cycle.
                const back = rnd.uintLessThan(u8, 12) == 0;
                const to = if (back) rnd.uintLessThan(usize, nodes.len) else i + 1 + rnd.uintLessThan(usize, 3);
                if (to >= nodes.len) continue;
                h.* = &nodes[to];
                row[to] = true;
            };
            node.* = .{ .left = held[0], .right = held[1] };
        }
        for (0..nodes.len) |k| for (0..nodes.len) |i| for (0..nodes.len) |j| {
            if (reaches[i][k] and reaches[k][j]) reaches[i][j] = true;
        };
        var cyclic = reaches[0][0];
        for (0..nodes.len) |k| cyclic = cyclic or (reaches[0][k] and reaches[k][k]);
        try expectCycle(cyclic, &nodes[0]);
    }
}

test "hasCycle: cycles too long for the stack" {
    const Pair = cycle_test.Pair;
    const nodes = try std.testing.allocator.alloc(Pair, 1_000_000);
    defer std.testing.allocator.free(nodes);
    var leaf: Pair = .{};
    // The next message of the cycle is the last one held, then the first.
    for (nodes, 1..) |*node, i| node.* = .{ .left = &leaf, .right = &nodes[i % nodes.len] };
    try expectCycle(true, &nodes[0]);
    nodes[nodes.len - 1].right = null;
    try expectCycle(false, &nodes[0]);
    for (nodes, 1..) |*node, i| node.* = .{ .left = &nodes[i % nodes.len], .right = &leaf };
    try expectCycle(true, &nodes[0]);
    nodes[nodes.len - 1].left = null;
    try expectCycle(false, &nodes[0]);
}

test "hasCycle: lists too long for the stack" {
    const ListCycle = cycle_test.ListCycle;
    const items = try std.testing.allocator.alloc(ListCycle, 1_000_000);
    defer std.testing.allocator.free(items);
    @memset(items, .{});
    var root: ListCycle = .{ .kids = .fromOwnedSlice(items) };
    try expectCycle(false, &root);
    items[items.len - 1].next = &root;
    try expectCycle(true, &root);
    items[items.len - 1].next = null;
    // Lists in a list, one of them empty.
    for (items[0..1000], 0..) |*item, i| item.kids = .fromOwnedSlice(items[1000 + i * 99 ..][0 .. i % 100]);
    root.kids = .fromOwnedSlice(items[0..1000]);
    try expectCycle(false, &root);
    items[1000 + 998 * 99 + 97].next = &root;
    try expectCycle(true, &root);
}

test "hasCycle: allocates only for the messages that wait for others" {
    const Pair = cycle_test.Pair;
    var nodes: [1000]Pair = undefined;
    var leaf: Pair = .{};
    const failing = std.testing.failing_allocator;
    // Nothing waits while the last message held is followed.
    for (&nodes, 1..) |*node, i| node.* = .{ .left = &leaf, .right = if (i < nodes.len) &nodes[i] else null };
    try std.testing.expect(!try hasCycle(&nodes[0], failing));
    nodes[nodes.len - 1].right = &nodes[0];
    try std.testing.expect(try hasCycle(&nodes[0], failing));
    // One message waits at each level: the buffer holds 32 of them.
    for (nodes[0..33], 1..) |*node, i| node.* = .{ .left = if (i < 33) &nodes[i] else null, .right = if (i < 33) &leaf else null };
    try std.testing.expect(!try hasCycle(&nodes[0], failing));
    for (&nodes, 1..) |*node, i| node.* = .{ .left = if (i < nodes.len) &nodes[i] else null, .right = &leaf };
    try std.testing.expectError(error.OutOfMemory, hasCycle(&nodes[0], failing));
    try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
        fn check(allocator: std.mem.Allocator, message: *const Pair) !void {
            try std.testing.expect(!try hasCycle(message, allocator));
        }
    }.check, .{&nodes[0]});
}

test "hasCycle: a cycle through each message of a list" {
    const ListCycle = cycle_test.ListCycle;
    var kids: [4]ListCycle = undefined;
    for (1..kids.len + 1) |len| for (0..len) |back| {
        @memset(&kids, .{});
        var root: ListCycle = .{ .kids = .fromOwnedSlice(kids[0..len]) };
        try expectCycle(false, &root);
        kids[back].next = &root;
        try expectCycle(true, &root);
    };
}

test "hasCycle: fields that lead to no loop through a pointer are not followed" {
    const t = cycle_test;
    var elements: [1]t.ListA = .{.{}};
    elements[0].arr = .{ .values = .fromOwnedSlice(&elements) };
    var msg: t.PtrAndList = .{ .list = elements[0] };
    try expectCycle(false, &msg);
    msg.next = &msg;
    try expectCycle(true, &msg);
}

test "hasCycle: the way of walking" {
    if (builtin.zig_backend == .stage2_llvm and builtin.cpu.arch == .x86_64) {
        try std.testing.expectEqual(.tail_calls, supported_way);
    }
    if (builtin.zig_backend != .stage2_llvm) try std.testing.expectEqual(.loop, supported_way);
}

test "hasCycle: many calls in one function" {
    var plain: cycle_test.Plain = .{};
    var self_ptr: cycle_test.SelfPtr = .{};
    var allocator = std.testing.failing_allocator;
    _ = .{ &plain, &self_ptr, &allocator };
    inline for (0..500) |_| {
        if (try hasCycle(&plain, allocator)) @compileError("compiled");
        try std.testing.expect(!try hasCycle(&self_ptr, allocator));
    }
}

test "hasCycle: known at compile time for messages that cannot hold a cycle" {
    // Both the value and the allocator are unknown at compile time.
    var plain: cycle_test.Plain = .{};
    var list: cycle_test.ListA = .{};
    var allocator = std.testing.failing_allocator;
    _ = .{ &plain, &list, &allocator };
    if (try hasCycle(&plain, allocator)) @compileError("compiled");
    if (try hasCycle(plain, allocator)) @compileError("compiled");
    // Recursion through lists only is not followed.
    if (try hasCycle(&list, allocator)) @compileError("compiled");
}

test "hasCycle: nesting at the same address is not a cycle" {
    var other: cycle_test.ByValue = .{ .inner = .{} };
    var o: cycle_test.ByValue = .{ .inner = .{ .back = &other } };
    try std.testing.expect(@intFromPtr(&o) == @intFromPtr(&o.inner.?));
    try expectCycle(false, &o);
}

test "hasCycle: a cycle around the large graph" {
    // `tree` goes down `left`, by value, to its leftmost leaf.
    var root: cycle_test.BigRoot = .{};
    root.tree = .{ .left = .{ .left = .{ .left = .{ .left = .{
        .left = .{ .left = .{ .left = .{ .left = .{} } } },
    } } } } };
    const leaf = &root.tree.?.left.?.left.?.left.?.left.?.left.?.left.?.left.?.left.?;
    leaf.back = &root;
    try expectCycle(true, &root);
    leaf.back = null;
    try expectCycle(false, &root);
}
