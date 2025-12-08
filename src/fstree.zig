const std = @import("std");
const Allocator = std.mem.Allocator;
const Dir = std.fs.Dir;
const fs = std.fs;

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
};

pub const Node = struct {
    basename: []const u8,
    path: []const u8,
    size_b: u64,
    kind: fs.File.Kind,
    layout: ?LayoutRect = null,

    children: std.ArrayList(*Node),
    parent: ?*Node,
};

pub fn copywalk(directory: Dir, allocator: Allocator) !*Node {
    const StackItem = struct {
        // Original (from FS)
        iter: Dir.Iterator,
        dirname_len: usize,
        // Copy (node tree)
        node: *Node,
    };
    var gpa = allocator;
    var stack: std.ArrayList(StackItem) = .empty;
    const root_node = try gpa.create(Node);
    root_node.* = .{
        .basename = try gpa.dupe(u8, ""),
        .path = try directory.realpathAlloc(gpa, "."),
        .size_b = 0,
        .kind = .directory,
        .children = .empty,
        .parent = null,
    };
    try stack.append(allocator, .{
        .iter = directory.iterate(),
        .dirname_len = 0,
        .node = root_node,
    });
    defer stack.deinit(gpa);
    var name_buffer: std.ArrayList(u8) = .empty;
    defer name_buffer.deinit(gpa);
    while (stack.items.len != 0) {
        var top = &stack.items[stack.items.len - 1];
        // This line can raise Dir.IteratorError.
        // Example: AccessDenied and similar.
        // TODO: We want it to be skipped with a warning in the
        // final version
        while (try top.iter.next()) |base| {
            var dirname_len = top.dirname_len;
            // Obtain path e basename keeping in mind the previous node infos
            // using a lot of trinks about shrinking and appending to
            // an ArrayList. Optimized for low amount of allocations.
            name_buffer.shrinkRetainingCapacity(dirname_len);
            if (name_buffer.items.len != 0) {
                try name_buffer.append(gpa, fs.path.sep);
                dirname_len += 1;
            }
            try name_buffer.ensureUnusedCapacity(gpa, base.name.len);
            name_buffer.appendSliceAssumeCapacity(base.name);
            // Create node
            if (base.kind == .directory or base.kind == .file) {
                const new_node = try gpa.create(Node);
                new_node.* = .{
                    .basename = try gpa.dupe(u8, base.name),
                    .path = try gpa.dupe(u8, name_buffer.items),
                    .size_b = if (base.kind == .file) (try top.iter.dir.statFile(base.name)).size else 0,
                    .kind = base.kind,
                    .children = .empty,
                    .parent = top.node,
                };
                try top.node.children.append(gpa, new_node);
                if (base.kind == .directory) {
                    var new_dir = top.iter.dir.openDir(base.name, .{ .iterate = true }) catch |err| switch (err) {
                        error.NameTooLong => unreachable, // no path sep in base.name
                        else => |e| return e,
                    };
                    // TODO: why the scope? for the errdefer?
                    {
                        errdefer new_dir.close();
                        try stack.append(gpa, .{
                            .iter = new_dir.iterateAssumeFirstIteration(),
                            .dirname_len = name_buffer.items.len,
                            .node = new_node,
                        });
                        top = &stack.items[stack.items.len - 1];
                    }
                }
            }
            // const estimate = base.name.len + dirname_len + 1;
            // std.debug.print("File {s} {d} = {d}\n", .{ name_buffer.items, name_buffer.items.len, estimate });
        }
        var item = stack.pop().?;
        if (stack.items.len != 0) {
            item.iter.dir.close();
        }
    }
    return root_node;
}

// Calculate Size by iterating on all node that are files
//   and then using the parent link to bubble up the size until
//   you reach root.
pub fn calculate_tree_size(node: *Node) u64 {
    if (node.kind == .file) {
        return node.size_b;
    } else if (node.kind == .directory) {
        var total_size: u64 = 0;
        for (node.children.items) |childnode| {
            total_size += calculate_tree_size(childnode);
        }
        node.size_b = total_size;
        return total_size;
    } else {
        return 0;
    }
}

const DimLocked = enum {
    width, // New Items are put at right of latest. Row Width is CONSTANT, row is Horizontal
    height, // New Items are put up of latest. Row Height is CONSTANT, row is Vertical
};
const RowState = struct {
    nodes: std.ArrayList(*Node),
    dim_locked: DimLocked,
    layout: LayoutRect,
    row_size_b: u64,

    const Self = @This();
    pub fn init(free_layout: LayoutRect) Self {
        const myself: Self = undefined;
        myself.nodes = .empty;
        myself.reset(free_layout);
        return myself;
    }
    pub fn reset(self: *Self, free_layout: LayoutRect) void {
        self.nodes.clearRetainingCapacity();
        self.dim_locked = if (free_layout.width() >= free_layout.height()) .{.height} else .{.width};
        self.layout = .{
            .upper_left = free_layout.lower_left(),
            .lower_right = free_layout.lower_left(),
        };
        self.row_size_b = 0;
    }
    pub fn aspect_ratio(self: Self) f32 {
        const max: f32 = @floatFromInt(@max(self.layout.height(), self.layout.width()));
        const min: f32 = @floatFromInt(@min(self.layout.height(), self.layout.width()));
        return max / min;
    }
    pub fn aspect_ratio_with(self: Self, node: *Node) f32 {
        const max: f32 = @floatFromInt(@max(self.layout.height(), self.layout.width()));
        const min: f32 = @floatFromInt(@min(self.layout.height(), self.layout.width()));
        return 1.0;
    }
    pub fn insert(self: *Self, node: *Node, free_layout: *LayoutRect) void {}
};

// COORDINATE SYSTEM IS 0,0 UPPER LEFT!
// X is HORIZONTAL (0 left)
// Y is VERTICAL (0 up)
// Il root_node need to have a Layout
pub fn calculate_layout(allocator: Allocator, root_node: *Node) !void {
    const gpa = allocator;
    const root_layout = root_node.layout.?; // TODO add check
    var free_rect: LayoutRect = root_layout;
    // Row State
    const current_row: std.ArrayList(*Node) = .empty;
    const DimLocked = union(enum) {
        width: i32, // New Items are put at right of latest. Row Width is CONSTANT, row is Horizontal
        height: i32, // New Items are put up of tlatest. Row Height is CONSTANT, row is Vertical
    };
    // Initial row is on the lower_left and has size zero
    var row_layout: LayoutRect = .{
        .upper_left = root_layout.lower_left(),
        .lower_right = root_layout.lower_left(),
    };
    var row_size = 0;
    var node_stack: std.ArrayList(*Node) = .empty;
    try node_stack.append(gpa, root_node);
    while (node_stack.pop()) |node| {}
}

pub fn calculate_layout_old(allocator: Allocator, root_node: *Node, initial_free_rect: LayoutRect) !void {
    const gpa = allocator;
    var free_rect = initial_free_rect;
    var free_h = free_rect.height();
    var free_w = free_rect.width();
    var root_size = root_node.size_b;
    const root_area = free_h * free_w;
    const current_row: std.ArrayList(*Node) = .empty;
    const DimLocked = union(enum) {
        width: i32, // New Items are put at right of latest. Row Width is CONSTANT, row is Horizontal
        height: i32, // New Items are put up of tlatest. Row Height is CONSTANT, row is Vertical
    };
    var row_height: i32 = 0;
    var row_width: i32 = 0;
    var row_size: u64 = 0;
    // Row Direction is so that the constant dim is the lowest of the free_rect. Small height = Row with locked Height = VERTICAL.
    var row_dir: DimLocked = undefined;
    var node_stack: std.ArrayList(*Node) = .empty;
    try node_stack.append(gpa, root_node);
    while (node_stack.pop()) |node| {
        var node_size = node.size_b;
        var node_ratio: f64 = node.size_b / root_node.size_b;
        // If row is empty, ez
        if (current_row.items.len == 0) {
            row_dir = if (free_w >= free_h) .{ .height = free_h } else .{ .width = free_w };
            node.layout = switch (row_dir) {
                .height => |fixed_h| .{
                    .upper_left = free_rect.upper_left,
                    .lower_right = .{ .x = node_ratio * free_w, .y = fixed_h },
                },
                .width => .{
                    .upper_left = .{ .x = 0, .y = free_rect.upper_left.x - node_ratio * free_h },
                    .lower_right = free_rect.lower_right,
                },
            };
            row_height += node.layout.?.height();
            row_width += node.layout.?.width();
            row_size += node.size_b;
            try current_row.append(gpa, node);
            continue;
        }
        // If row not empty, adding it can it reduce the aspect ratio of the ROW
        const old_max: f32 = @floatFromInt(@max(row_height, row_width));
        const old_min: f32 = @floatFromInt(@min(row_height, row_width));
        const old_ar = old_max / old_min;
        const new_ar: f32 = switch (row_dir) {
            .height => |fixed_h| blk: {
                const h: f32 = @floatFromInt(fixed_h);
                const w: f32 = @floatFromInt(row_width + node_ratio * free_w);
                break :blk w / h;
            },
            .width => |fixed_w| blk: {
                const h: f32 = @floatFromInt(row_height + node_ratio * free_h);
                const w: f32 = @floatFromInt(fixed_w);
                break :blk h / w;
            },
        };
        if (new_ar < old_ar) {
            row_size += node.size_b;
            // Dovrebbero usare i dati della riga, non di free
            switch (row_dir) {
                .height => |fixed_h| {
                    const new_row_w: i32 = @intFromFloat(new_ar * fixed_h);
                    for (current_row.items) |old_node| {
                        const new_node_h: i32 = old_node.size_b / root_size * root_area / new_row_w;
                        old_node.layout.?.lower_right.x = old_node.layout.?.upper_left.x + new_row_w;
                        old_node.layout.?.upper_left.y = old_node.layout.?.lower_right.y - new_node_h;
                    }
                    const this_node_h: i32 = node.size_b / root_size * root_area / new_row_w;
                    node.layout = .{ .upper_left = free_rect.upper_left, .lower_right = .{
                        .x = free_rect.lower_right.x - new_row_w,
                        .y = this_node_h,
                    } };
                    // node.layout = .{
                    //     .lower_right = free_rect.lower_right,
                    //     .upper_left = .{
                    //         .x = free_rect.lower_right.x - new_row_w,
                    //         .y = free_rect.lower_right
                    //     }
                    // }
                },
                .width => |fixed_w| {
                    const new_row_h: i32 = @intFromFloat(new_ar * fixed_w);
                    for (current_row.items) |old_node| {
                        const new_node_w: i32 = old_node.size_b / root_size * root_area / new_row_h;
                        old_node.layout.?.upper_left.y = old_node.layout.?.lower_right.y - new_row_h;
                        old_node.layout.?.lower_right.x = old_node.layout.?.upper_left.x + new_node_w;
                    }
                },
            }
        }
    }
}

const LayoutItem = struct { node: *Node, width: i32, height: i32 };

// A div can have as childrens only ALL items or ALL divs
// Every item is inside a Div with only him as child
const LayoutDiv = struct {
    node: *Node,
    width: i32,
    height: i32,
    direction: enum { left_right, up_down },
    children: std.ArrayList(LayoutElement),
};

const LayoutElement = union(enum) {
    div: LayoutDiv,
    item: LayoutItem,
};

pub fn calculate_rect_old(allocator: Allocator, node: *Node, width: i32, height: i32) void {
    const gpa = allocator;
    node.dwright = .{ .x = width, .y = height };
    var stack: std.ArrayList(*Node) = .empty;
    for (node.children.items) |child| {
        if (child.kind == .directory) {
            try stack.append(gpa, child);
        }
    }
    const layout_tree = try gpa.create(LayoutDiv);
    layout_tree.* = .{
        .node = node,
        .width = width,
        .height = height,
        .direction = if (width < height) .left_right else .up_down,
        .children = .empty,
    };
    for (node.children.items) |child| {}
    while (stack.items.len != 0) {
        const top = stack.pop().?;
        // Calculate layout info for all child

        // Add to stack other childs for future inspection
        for (top.children.items) |child| {
            if (child.kind == .directory) {
                try stack.append(gpa, child);
            }
        }
    }
}
