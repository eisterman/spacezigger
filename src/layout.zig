const std = @import("std");
const fstree = @import("fstree.zig");
const Allocator = std.mem.Allocator;
const FsNode = fstree.FsNode;

// Layer 1: Pure Geometry
const Axis = enum {
    horizontal,
    vertical,

    pub fn other(self: @This()) @This() {
        return switch (self) {
            .horizontal => .vertical,
            .vertical => .horizontal,
        };
    }
};

pub const Point = struct {
    x: i32,
    y: i32,
};

pub const LayoutRect = struct {
    upper_left: Point = .{ .x = 0, .y = 0 },
    lower_right: Point = .{ .x = 0, .y = 0 },

    const Self = @This();
    pub fn width(self: Self) i32 {
        return self.lower_right.x - self.upper_left.x;
    }
    pub fn height(self: Self) i32 {
        return self.lower_right.y - self.upper_left.y;
    }
    pub fn get_axis(self: Self, axis: Axis) i32 {
        return switch (axis) {
            .vertical => self.height(),
            .horizontal => self.width(),
        };
    }
    pub fn lower_left(self: Self) Point {
        return .{
            .x = self.upper_left.x,
            .y = self.lower_right.y,
        };
    }
    pub fn upper_right(self: Self) Point {
        return .{
            .x = self.lower_right.x,
            .y = self.upper_left.y,
        };
    }
    pub fn center(self: Self) Point {
        return .{
            .x = self.upper_left.x + @divTrunc(self.width(), 2),
            .y = self.upper_left.y + @divTrunc(self.height(), 2),
        };
    }
    pub fn abs_aspect_ratio(self: Self) f32 {
        const max: f32 = @floatFromInt(@max(self.height(), self.width()));
        const min: f32 = @floatFromInt(@min(self.height(), self.width()));
        if (min == 0.0) return std.math.inf(f32);
        return max / min;
    }
    // Return the same layout with zeroed axis (fixed point is lower-left)
    pub fn toEmptyAxis(self: Self, axis: Axis) Self {
        var res = self;
        switch (axis) {
            .horizontal => res.lower_right.x = res.upper_left.x,
            .vertical => res.upper_left.y = res.lower_right.y,
        }
        return res;
    }
    pub fn splitHorizontal(self: Self, ratio: f32) struct { top: Self, bottom: Self } {
        const split_y = self.upper_left.y + @as(i32, @intFromFloat(@as(f32, @floatFromInt(self.height())) * ratio));
        return .{
            .top = .{ .upper_left = self.upper_left, .lower_right = .{ .x = self.lower_right.x, .y = split_y } },
            .bottom = .{ .upper_left = .{ .x = self.upper_left.x, .y = split_y }, .lower_right = self.lower_right },
        };
    }
    pub fn splitVertical(self: Self, ratio: f32) struct { left: Self, right: Self } {
        const split_x = self.upper_left.x + @as(i32, @intFromFloat(@as(f32, @floatFromInt(self.width())) * ratio));
        return .{
            .left = .{ .upper_left = self.upper_left, .lower_right = .{ .x = split_x, .y = self.lower_right.y } },
            .right = .{ .upper_left = .{ .x = split_x, .y = self.upper_left.y }, .lower_right = self.lower_right },
        };
    }
    fn shorterAxis(self: Self) Axis {
        return if (self.width() >= self.height()) .vertical else .horizontal;
    }
};

// computeWorstAspectRatio calculates the worst (highest) aspect ratio among a row of items
// in a treemap layout.
//
// The function takes the dimensions of a row present layout and size,
// and compute the worst aspect ratio between all nodes whe the row has that layout.
//
// This function is used by the squarified treemap algorithm to evaluate the quality of a
// potential row arrangement. Lower worst aspect ratios indicate more square-like rectangles,
// which are generally more desirable for visualization.
//
// Parameters:
//   - fixed_dimension: The dimension that remains constant for all items in the row
//                      (e.g., height for a horizontal row, width for a vertical row)
//   - total_variable_dimension: The total available space in the variable dimension
//                       (e.g., total width for a horizontal row)
//   - sizes: Array of file/directory sizes to be laid out in this row
//   - total_size: Sum of all sizes in the sizes array
//
// Returns:
//   The worst (maximum) aspect ratio found among all items in the row
fn computeWorstAspectRatio(
    fixed_dimension: i32,
    total_variable_dimension: i32,
    sizes: []const u64,
    total_size: u64,
) f32 {
    const fixed: f32 = @floatFromInt(fixed_dimension);
    const moving: f32 = @floatFromInt(total_variable_dimension);
    const total: f32 = @floatFromInt(total_size);

    var worst: f32 = 0.0;
    for (sizes) |size| {
        const ratio = @as(f32, @floatFromInt(size)) / total;
        const item_fixed_part = ratio * fixed;
        const ar = if (moving > item_fixed_part) moving / item_fixed_part else item_fixed_part / moving;
        worst = @max(worst, ar);
    }
    return worst;
}

pub const LayoutNode = struct {
    fsnode: *FsNode,
    box_layout: LayoutRect,

    children: std.ArrayList(*LayoutNode),
    parent: ?*LayoutNode,

    const Self = @This();
    pub fn init_from_fsnode(fsnode: *FsNode, box_layout: LayoutRect, parent: ?*LayoutNode) Self {
        return Self{
            .fsnode = fsnode,
            .box_layout = box_layout,
            .children = .empty,
            .parent = parent,
        };
    }

    pub fn content_layout(self: Self) LayoutRect {
        if (self.box_layout.height() < 32) {
            return .{
                .upper_left = .{
                    .x = self.box_layout.upper_left.x + 2,
                    .y = self.box_layout.upper_left.y + 2,
                },
                .lower_right = .{
                    .x = self.box_layout.lower_right.x - 2,
                    .y = self.box_layout.lower_right.y - 2,
                },
            };
        } else {
            return .{
                .upper_left = .{
                    .x = self.box_layout.upper_left.x + 2,
                    .y = self.box_layout.upper_left.y + 14,
                },
                .lower_right = .{
                    .x = self.box_layout.lower_right.x - 2,
                    .y = self.box_layout.lower_right.y - 2,
                },
            };
        }
    }

    pub fn namebox_layout(self: Self) ?LayoutRect {
        // If return null, doesn't draw it.
        if (self.box_layout.height() < 32 or self.box_layout.width() < 4) {
            return null;
        } else {
            return .{
                .upper_left = .{
                    .x = self.box_layout.upper_left.x + 2,
                    .y = self.box_layout.upper_left.y + 2,
                },
                .lower_right = .{
                    .x = self.box_layout.lower_right.x - 2,
                    .y = self.box_layout.upper_left.y + 14,
                },
            };
        }
    }

    pub fn deinit(self: *Self, gpa: Allocator) void {
        for (self.children.items) |c| {
            c.deinit(gpa);
        }
        self.children.deinit(gpa);
        // TODO: probably it's best to NOT self-destroy to allow stack-based nodes to be used!
        gpa.destroy(self);
    }
};

const RowPhase = enum {
    accumulating,
    finalized,
};

const DimLocked = enum {
    width, // New Items are put at right of latest. Row Width is CONSTANT, row is Horizontal
    height, // New Items are put up of latest. Row Height is CONSTANT, row is Vertical

    const Self = @This();
    pub fn from_layout_shorter_size(axis: Axis) Self {
        // We keep locked the direction corresponding to the shorter size
        return switch (axis) {
            .vertical => .width,
        };
    }
};

const FreeState = struct {
    layout: LayoutRect,
    size_b: u64,
};

const RowBuilder = struct {
    phase: RowPhase,
    axis_locked: Axis,
    fsnodes: std.ArrayList(*FsNode),
    layout: LayoutRect,
    size_b: u64,

    // FreeState
    free_state: FreeState,

    // Working on
    cache_worst_aspect_ratio: f32,
    cache_nodes_sizes: std.ArrayList(u64),

    const Self = @This();
    pub fn init() Self {
        var state: Self = undefined;
        state.fsnodes = .empty;
        state.cache_nodes_sizes = .empty;
        return state;
    }
    pub fn reset(self: *Self, free_state: FreeState) void {
        // const free_state: FreeState = .{
        //     .layout = base_layout_node.content_layout(),
        //     .size_b = base_layout_node.fsnode.size_b,
        // };
        self.phase = .accumulating;
        self.axis_locked = free_state.layout.shorterAxis();
        self.fsnodes.clearRetainingCapacity();
        self.layout = free_state.layout.toEmptyAxis(self.axis_locked.other());
        self.size_b = 0;
        self.free_state = free_state;
        self.cache_worst_aspect_ratio = std.math.inf(f32);
        self.cache_nodes_sizes.clearRetainingCapacity();
    }

    // TODO: Resetter per non rialloccare
    pub fn try_insert_fsnode(self: *Self, gpa: Allocator, fsnode: *FsNode) !enum { inserted, rejected } {
        if (self.phase == .finalized) return .rejected;
        const free_size_b_f32: f32 = @floatFromInt(self.free_state.size_b);
        const fsnode_size_b_f32: f32 = @floatFromInt(fsnode.size_b);
        const size_ratio: f32 = fsnode_size_b_f32 / free_size_b_f32;
        // Dimension agnostic calculator of the new row layout with fsnode included
        const new_row_layout: LayoutRect, const dimension_delta = switch (self.axis_locked) {
            .horizontal => blk: {
                var res = self.layout;
                const free_h: f32 = @floatFromInt(self.free_state.layout.height());
                const delta_row_h: i32 = @intFromFloat(free_h * size_ratio);
                res.upper_left.y -= delta_row_h;
                break :blk .{ res, delta_row_h };
            },
            .vertical => blk: {
                var res = self.layout;
                const free_w: f32 = @floatFromInt(self.free_state.layout.width());
                const delta_row_w: i32 = @intFromFloat(free_w * size_ratio);
                res.lower_right.x += delta_row_w;
                break :blk .{ res, delta_row_w };
            },
        };
        // Check worst aspect ratio from cache
        const worst_aspect_ratio_old = self.cache_worst_aspect_ratio;
        // Compute worst aspect ratio with new node
        const new_row_fixed_length = new_row_layout.get_axis(self.axis_locked);
        const new_row_moving_length = new_row_layout.get_axis(self.axis_locked.other());
        // Usa la cache dei sizes per questo lavoro
        // TODO: move cache_nodes_sizes inside his own struct
        try self.cache_nodes_sizes.append(gpa, fsnode.size_b);
        const new_all_node_size_b = self.size_b + fsnode.size_b;
        const worst_aspect_ratio_with_new = computeWorstAspectRatio(new_row_fixed_length, new_row_moving_length, self.cache_nodes_sizes.items, new_all_node_size_b);
        if (self.fsnodes.items.len == 0 or worst_aspect_ratio_with_new <= worst_aspect_ratio_old) {
            // Apply change to row
            self.layout = new_row_layout;
            self.size_b = new_all_node_size_b;
            self.cache_worst_aspect_ratio = worst_aspect_ratio_with_new;
            try self.fsnodes.append(gpa, fsnode);
            // Apply change to free_state
            self.free_state.size_b -= fsnode.size_b;
            switch (self.axis_locked) {
                .horizontal => self.free_state.layout.lower_right.y -= dimension_delta,
                .vertical => self.free_state.layout.upper_left.x += dimension_delta,
            }
            return .inserted;
        } else {
            // Restore previous state on the array
            _ = self.cache_nodes_sizes.pop();
            self.phase = .finalized;
            return .rejected;
        }
    }
    // TODO: trasforma in LayoutNode.register_rowbuilder() e che controlli se lo stato e' finalized?
    pub fn register_layout(self: *Self, gpa: Allocator, base_layout_node: *LayoutNode) !void {
        // Here we keep source of truth for size_b as u64 because
        // f32 start to lose integer precision over 8 milion, a number
        // really easy to surpass with file size.
        var free = FreeState{
            .layout = self.layout,
            .size_b = self.size_b,
        };
        for (self.fsnodes.items) |fsnode| {
            const free_size_b_f32: f32 = @floatFromInt(free.size_b);
            const fsnode_size_b_f32: f32 = @floatFromInt(fsnode.size_b);
            const ratio: f32 = fsnode_size_b_f32 / free_size_b_f32;
            switch (self.axis_locked) {
                .horizontal => {
                    const free_w: f32 = @floatFromInt(free.layout.width());
                    const delta_w: i32 = @intFromFloat(ratio * free_w);
                    const new_layout = LayoutRect{
                        .upper_left = free.layout.upper_left,
                        .lower_right = .{
                            .x = free.layout.upper_left.x + delta_w,
                            .y = free.layout.lower_right.y,
                        },
                    };
                    const node = try gpa.create(LayoutNode);
                    node.* = LayoutNode.init_from_fsnode(fsnode, new_layout, base_layout_node);
                    try base_layout_node.children.append(gpa, node);
                    free.layout.upper_left.x += delta_w;
                    free.size_b -= fsnode.size_b;
                },
                .vertical => {
                    const free_h: f32 = @floatFromInt(free.layout.height());
                    const delta_h: i32 = @intFromFloat(ratio * free_h);
                    const new_layout = LayoutRect{
                        .upper_left = .{
                            .x = free.layout.upper_left.x,
                            .y = free.layout.lower_right.y - delta_h,
                        },
                        .lower_right = free.layout.lower_right,
                    };
                    const node = try gpa.create(LayoutNode);
                    node.* = LayoutNode.init_from_fsnode(fsnode, new_layout, base_layout_node);
                    try base_layout_node.children.append(gpa, node);
                    free.layout.lower_right.y -= delta_h;
                    free.size_b -= fsnode.size_b;
                },
            }
        }
    }
};

// Data structure with FsNode as sorted
const FsNodesBySizeDesc = struct {
    data: std.ArrayList(*FsNode) = .empty,

    pub const empty: Self = .{ .data = .empty };

    const Self = @This();
    pub fn deinit(self: *Self, gpa: Allocator) void {
        self.data.deinit(gpa);
        self.* = undefined;
    }

    const SortBySizeDesc = struct {
        fn handler(_: void, lhs: *FsNode, rhs: *FsNode) bool {
            return lhs.size_b > rhs.size_b;
        }
    };

    pub fn appendSort(self: *Self, gpa: Allocator, items: []const *FsNode) Allocator.Error!void {
        self.data.clearRetainingCapacity();
        try self.data.appendSlice(gpa, items);
        std.sort.block(*FsNode, self.data.items, {}, SortBySizeDesc.handler);
    }
};

pub fn build_layout(gpa: Allocator, base_fsnode: *FsNode, base_layout: LayoutRect) !*LayoutNode {
    const layout_root = try gpa.create(LayoutNode);
    layout_root.* = LayoutNode.init_from_fsnode(base_fsnode, base_layout, null);
    // State
    var node_stack: std.ArrayList(*LayoutNode) = .empty;
    try node_stack.append(gpa, layout_root);
    // Scratches
    var row_builder = RowBuilder.init();
    var sorted_children: FsNodesBySizeDesc = .empty;
    while (node_stack.pop()) |parent_node| {
        var free_state = FreeState{
            .layout = parent_node.content_layout(),
            .size_b = parent_node.fsnode.size_b,
        };
        row_builder.reset(free_state);
        try sorted_children.appendSort(gpa, parent_node.fsnode.children.items);
        for (sorted_children.data.items) |child_fsnode| {
            if (child_fsnode.size_b == 0) {
                std.debug.print("Rejected zero-sized node {s}\n", .{child_fsnode.path});
                continue;
            }
            if (try row_builder.try_insert_fsnode(gpa, child_fsnode) == .rejected) {
                // Rejected = Row has been completed. Empty the builder and register the layout
                try row_builder.register_layout(gpa, parent_node);
                free_state = row_builder.free_state;
                // Create new row and try to insert
                row_builder.reset(free_state);
                if (try row_builder.try_insert_fsnode(gpa, child_fsnode) == .rejected) {
                    std.debug.print("Node lost: {s}\n", .{child_fsnode.path});
                    // Unreachable?
                }
            }
            // AAAAAAAAAAAAAAAAAAAAAAAAAAAA
            // Questo sistema non e' possibile perche prima, li registravo senza avere
            // i layout perche tanto poi al register sarebbero apparsi, adesso invece
            // lo devo fare AL MOMENTO DEL REGISTER_LAYOUT o alla fine, iterando su parent_node
            // separatamente
            // Finished children nodes. Append child to node_stack if is a parent
            // if (child_fsnode.kind == .directory) {
            // On paper there is to insert at index 0, but I think append to end
            // is not a problem because folders don't overlap.
            // try node_stack.append(gpa, child_fsnode);
            // }
        }
        // Finished children. Register last row if not empty
        if (row_builder.fsnodes.items.len != 0) {
            try row_builder.register_layout(gpa, parent_node);
        }
        // Register folders
        for (parent_node.children.items) |child_layout_node| {
            if (child_layout_node.fsnode.kind == .directory) {
                try node_stack.append(gpa, child_layout_node);
            }
        }
    }
    return layout_root;
}
