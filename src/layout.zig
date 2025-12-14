const std = @import("std");
const Allocator = std.mem.Allocator;
const fstree = @import("fstree.zig");
const Point = fstree.Point;
const LayoutRect = fstree.LayoutRect;
const Node = fstree.Node;

const DimLocked = enum {
    width, // New Items are put at right of latest. Row Width is CONSTANT, row is Horizontal
    height, // New Items are put up of latest. Row Height is CONSTANT, row is Vertical
};

const RowState = struct {
    nodes: std.ArrayList(*Node),
    dim_locked: DimLocked,
    layout: LayoutRect,
    size_b: u64,
    cache_worst_aspect_ratio: f32,

    const Self = @This();
    pub const empty: Self = .{
        .nodes = .empty,
        .dim_locked = undefined,
        .layout = undefined,
        .size_b = 0,
        .cache_worst_aspect_ratio = std.math.inf(f32),
    };
    pub fn reset(self: *Self, free_layout: LayoutRect) void {
        self.nodes.clearRetainingCapacity();
        self.dim_locked = if (free_layout.width() >= free_layout.height()) .height else .width;
        self.layout = switch (self.dim_locked) {
            .height => .{
                .upper_left = free_layout.upper_left,
                .lower_right = free_layout.lower_left(),
            },
            .width => .{
                .upper_left = free_layout.lower_left(),
                .lower_right = free_layout.lower_right,
            },
        };
        self.size_b = 0;
        self.cache_worst_aspect_ratio = std.math.inf(f32);
    }
    pub fn deinit(self: *Self, gpa: Allocator) void {
        self.nodes.deinit(gpa);
        self.* = undefined;
    }
    pub const InsertResult = enum {
        inserted,
        rejected,
    };
    pub fn try_insert(self: *Self, gpa: Allocator, node: *Node, free_state: *FreeState) !InsertResult {
        const free_size_b: f32 = @floatFromInt(free_state.size_b);
        const node_size_b: f32 = @floatFromInt(node.size_b);
        const size_ratio: f32 = node_size_b / free_size_b;
        const new_row_layout: LayoutRect, const delta_dimension = switch (self.dim_locked) {
            .width => blk: {
                var res = self.layout;
                const free_h: f32 = @floatFromInt(free_state.layout.height());
                const delta_row_h: i32 = @intFromFloat(free_h * size_ratio);
                res.upper_left.y -= delta_row_h;
                break :blk .{ res, delta_row_h };
            },
            .height => blk: {
                var res = self.layout;
                const free_w: f32 = @floatFromInt(free_state.layout.width());
                const delta_row_w: i32 = @intFromFloat(free_w * size_ratio);
                res.lower_right.x += delta_row_w;
                break :blk .{ res, delta_row_w };
            },
        };
        // Check worst aspect ratios
        const old_war = self.cache_worst_aspect_ratio;
        // Update self with new tentative data
        try self.nodes.append(gpa, node);
        const new_row = FreeState{
            .layout = new_row_layout,
            .size_b = self.size_b + node.size_b,
        };
        const new_war = self.worst_aspect_ratio(self.nodes.items, new_row);
        if (self.nodes.items.len == 0 or new_war <= old_war) {
            // Apply change to self
            self.layout = new_row_layout;
            self.size_b += node.size_b;
            self.cache_worst_aspect_ratio = new_war;
            // Apply change to free_state
            free_state.size_b -= node.size_b;
            switch (self.dim_locked) {
                .width => free_state.layout.lower_right.y -= delta_dimension,
                .height => free_state.layout.upper_left.x += delta_dimension,
            }
            return .inserted;
        } else {
            // Restore previous state
            _ = self.nodes.pop();
            return .rejected;
        }
    }
    fn worst_aspect_ratio(self: Self, nodes: []const *Node, free_row: FreeState) f32 {
        // DISTRIBUTE Row free space to all nodes, and obtain the worst aspect ratio.
        // This legenda is for NODE layout, not for the ROW layout.
        // fxd -> fixed dimension; mov -> moving one
        const all_fxd: f32 = @floatFromInt(switch (self.dim_locked) {
            .width => free_row.layout.height(),
            .height => free_row.layout.width(),
        });
        const free_size_b: f32 = @floatFromInt(free_row.size_b);
        var war: f32 = 0.0;
        for (nodes) |node| {
            const node_size_b: f32 = @floatFromInt(node.size_b);
            const ratio: f32 = node_size_b / free_size_b;
            const free_mov: f32 = @floatFromInt(switch (self.dim_locked) {
                .width => free_row.layout.width(),
                .height => free_row.layout.height(),
            });
            const delta_mov: f32 = ratio * free_mov;
            // abs_aspect_ratio
            const node_war = abs_aspect_ratio: {
                const max: f32 = @max(all_fxd, delta_mov);
                const min: f32 = @min(all_fxd, delta_mov);
                break :abs_aspect_ratio if (min == 0.0) std.math.inf(f32) else max / min;
            };
            if (node_war > war) war = node_war;
        }
        return war;
    }
    pub fn register_layout(self: *Self) void {
        // Here we keep source of truth for size_b as u64 because
        // f32 start to lose integer precision over 8 milion, a number
        // really easy to surpass with file size.
        var free = FreeState{
            .layout = self.layout,
            .size_b = self.size_b,
        };
        for (self.nodes.items) |node| {
            const free_size_b: f32 = @floatFromInt(free.size_b);
            const node_size_b: f32 = @floatFromInt(node.size_b);
            const ratio: f32 = node_size_b / free_size_b;
            switch (self.dim_locked) {
                .width => {
                    const free_w: f32 = @floatFromInt(free.layout.width());
                    const delta_w: i32 = @intFromFloat(ratio * free_w);
                    const new_layout = LayoutRect{
                        .upper_left = free.layout.upper_left,
                        .lower_right = .{
                            .x = free.layout.upper_left.x + delta_w,
                            .y = free.layout.lower_right.y,
                        },
                    };
                    node.layout = new_layout;
                    free.layout.upper_left.x += delta_w;
                    free.size_b -= node.size_b;
                },
                .height => {
                    const free_h: f32 = @floatFromInt(free.layout.height());
                    const delta_h: i32 = @intFromFloat(ratio * free_h);
                    const new_layout = LayoutRect{
                        .upper_left = .{
                            .x = free.layout.upper_left.x,
                            .y = free.layout.lower_right.y - delta_h,
                        },
                        .lower_right = free.layout.lower_right,
                    };
                    node.layout = new_layout;
                    free.layout.lower_right.y -= delta_h;
                    free.size_b -= node.size_b;
                },
            }
        }
    }
};

const FreeState = struct {
    layout: LayoutRect,
    size_b: u64,
};

const NodesBySizeDesc = struct {
    data: std.ArrayList(*Node) = .empty,

    pub const empty: Self = .{ .data = .empty };

    const Self = @This();
    pub fn deinit(self: *Self, gpa: Allocator) void {
        self.data.deinit(gpa);
        self.* = undefined;
    }

    const SortBySizeDesc = struct {
        fn handler(_: void, lhs: *Node, rhs: *Node) bool {
            return lhs.size_b > rhs.size_b;
        }
    };

    pub fn appendSort(self: *Self, gpa: Allocator, items: []const *Node) Allocator.Error!void {
        self.data.clearRetainingCapacity();
        try self.data.appendSlice(gpa, items);
        std.sort.block(*Node, self.data.items, {}, SortBySizeDesc.handler);
    }
};

const LayouterError = error{
    MissingRootLayout,
};

pub fn calculate_layout(allocator: Allocator, root_node: *Node) !void {
    if (root_node.layout == null) return LayouterError.MissingRootLayout;
    const gpa = allocator;
    // State
    var row_state: RowState = .empty;
    defer row_state.deinit(gpa);
    var node_stack: std.ArrayList(*Node) = .empty;
    defer node_stack.deinit(gpa);
    // Scratches
    var sorted_children: NodesBySizeDesc = .empty;
    defer sorted_children.deinit(gpa);
    // Initialization
    try node_stack.append(gpa, root_node);
    while (node_stack.pop()) |parent_node| {
        var free_state = FreeState{
            .layout = parent_node.layout.?,
            .size_b = parent_node.size_b,
        };
        row_state.reset(free_state.layout);
        try sorted_children.appendSort(gpa, parent_node.children.items);
        for (sorted_children.data.items) |child_node| {
            if (child_node.size_b == 0) {
                std.debug.print("Rejected zero-sized node {s}\n", .{child_node.path});
                continue;
            }
            if (try row_state.try_insert(gpa, child_node, &free_state) == .rejected) {
                // Rejected = row completed.
                row_state.register_layout();
                // Create new row and try to insert
                row_state.reset(free_state.layout);
                if (try row_state.try_insert(gpa, child_node, &free_state) == .rejected) {
                    std.debug.print("Node lost: {s}\n", .{child_node.path});
                    // Unreachable?
                }
            }
            // Finished children nodes. Append child to node_stack if is a parent
            if (child_node.kind == .directory) {
                // On paper there is to insert at index 0, but I think append to end
                // is not a problem because folders don't overlap.
                try node_stack.append(gpa, child_node);
            }
        }
        // Finished children. Register last row if not empty
        if (row_state.nodes.items.len != 0) {
            row_state.register_layout();
        }
    }
}
