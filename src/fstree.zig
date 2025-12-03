const std = @import("std");
const Allocator = std.mem.Allocator;
const Dir = std.fs.Dir;
const fs = std.fs;

pub fn realpathAllocZ(self: Dir, allocator: Allocator, pathname: []const u8) Dir.RealPathAllocError![:0]u8 {
    // Use of max_path_bytes here is valid as the realpath function does not
    // have a variant that takes an arbitrary-size buffer.
    // TODO(#4812): Consider reimplementing realpath or using the POSIX.1-2008
    // NULL out parameter (GNU's canonicalize_file_name) to handle overelong
    // paths. musl supports passing NULL but restricts the output to PATH_MAX
    // anyway.
    var buf: [fs.max_path_bytes]u8 = undefined;
    return allocator.dupeZ(u8, try self.realpath(pathname, buf[0..]));
}

// TODO OVERFLOW
// Cerca di capire dove passano dei numeri a troppo alti.
// Il size in particolare e' ok che stia u64
// Pero quando avvengono calcoli di ratei tutto si sminchia perche
// i32 e' troppo piccolo per calcoli temporanei di size tra f32 e u64.
// Ridisegna le strutture dati.
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
};

pub const Node = struct {
    basename: [:0]const u8,
    path: [:0]const u8,
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
        .basename = try gpa.dupeZ(u8, "."),
        .path = try realpathAllocZ(directory, gpa, "."),
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
                    .basename = try gpa.dupeZ(u8, base.name),
                    .path = try gpa.dupeZ(u8, name_buffer.items),
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

const RootState = struct {
    free_layout: LayoutRect,
    total_size_b: u64,
    free_size_b: u64,
};

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
    pub const empty: Self = .{
        .nodes = .empty,
        .dim_locked = undefined,
        .layout = undefined,
        .row_size_b = 0,
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
        self.row_size_b = 0;
    }
    pub fn try_insert(self: *Self, gpa: Allocator, node: *Node, root_state: *RootState) !bool {
        const free_size_b: f32 = @floatFromInt(root_state.free_size_b);
        const node_size_f32: f32 = @floatFromInt(node.size_b);
        const size_ratio: f32 = node_size_f32 / free_size_b;
        const new_row_layout: LayoutRect, const delta_row = switch (self.dim_locked) {
            .width => blk: {
                var res = self.layout;
                const free_h: f32 = @floatFromInt(root_state.free_layout.height());
                const delta_row_h: i32 = @intFromFloat(free_h * size_ratio);
                res.upper_left.y -= delta_row_h;
                break :blk .{ res, delta_row_h };
            },
            .height => blk: {
                var res = self.layout;
                const free_w: f32 = @floatFromInt(root_state.free_layout.width());
                const delta_row_w: i32 = @intFromFloat(free_w * size_ratio);
                res.lower_right.x += delta_row_w;
                break :blk .{ res, delta_row_w };
            },
        };
        std.debug.print("NEW LAYOUT {}\n", .{new_row_layout});
        std.debug.print("ASPECTS {} {d} {d}\n", .{ self.nodes.items.len, new_row_layout.abs_aspect_ratio(), self.layout.abs_aspect_ratio() });
        if (self.nodes.items.len == 0 or new_row_layout.abs_aspect_ratio() <= self.layout.abs_aspect_ratio()) {
            self.layout = new_row_layout;
            self.row_size_b += node.size_b;
            try self.nodes.append(gpa, node);
            // Apply change to "free" data into root_state too
            root_state.free_size_b -= node.size_b;
            switch (self.dim_locked) {
                .width => root_state.free_layout.lower_right.y -= delta_row,
                .height => root_state.free_layout.upper_left.x += delta_row,
            }
            return true;
        } else {
            return false;
        }
    }
    pub fn register_layout(self: *Self) void {
        // Distribute the row space to sub-nodes
        std.debug.print("Starting Register Layout\n", .{});
        var free_row = self.layout;
        var free_size_b: f32 = @floatFromInt(self.row_size_b);
        std.debug.print("Starting free_size_b = {d}\n", .{free_size_b});
        std.debug.print("PORCODIO {}\n", .{self.nodes.items.len});
        for (self.nodes.items) |row_node| {
            const node_size_b: f32 = @floatFromInt(row_node.size_b);
            std.debug.print("Processing node {s}\n", .{row_node.path});
            const ratio: f32 = node_size_b / free_size_b;
            std.debug.print("\tSize {d}\n", .{node_size_b});
            std.debug.print("\tRatio {d}\n", .{ratio});
            switch (self.dim_locked) {
                .width => {
                    const free_h: f32 = @floatFromInt(free_row.height());
                    const delta_h: i32 = @intFromFloat(ratio * free_h);
                    std.debug.print("\tRatio {} = {d} / {d}\n", .{ ratio, node_size_b, free_size_b });
                    std.debug.print("\tWidth {} - {}\n", .{ free_row.lower_right.y, delta_h });
                    const new_layout = LayoutRect{
                        .upper_left = .{
                            .x = free_row.upper_left.x,
                            .y = free_row.lower_right.y - delta_h,
                        },
                        .lower_right = free_row.lower_right,
                    };
                    row_node.layout = new_layout;
                    free_row.lower_right.y -= delta_h;
                    free_size_b -= node_size_b;
                },
                .height => {
                    const free_w: f32 = @floatFromInt(free_row.width());
                    const delta_w: i32 = @intFromFloat(ratio * free_w);
                    const new_layout = LayoutRect{
                        .upper_left = free_row.upper_left,
                        .lower_right = .{
                            .x = free_row.upper_left.x + delta_w,
                            .y = free_row.lower_right.y,
                        },
                    };
                    row_node.layout = new_layout;
                    free_row.upper_left.x += delta_w;
                    free_size_b -= node_size_b;
                },
            }
            std.debug.print("Updated free_size_b {d}\n", .{free_size_b});
            // std.debug.print("Registering Layout {} for {s}\n", .{ row_node.layout.?, row_node.path });
        }
    }
};

pub fn margin(layout: LayoutRect, px: i32) LayoutRect {
    // TODO better margin algo
    if (2 * px > layout.width() or 2 * px > layout.height()) return layout;
    return .{
        .upper_left = .{
            .x = layout.upper_left.x + px,
            .y = layout.upper_left.y + px,
        },
        .lower_right = .{
            .x = layout.lower_right.x - px,
            .y = layout.lower_right.y - px,
        },
    };
}

// COORDINATE SYSTEM IS 0,0 UPPER LEFT!
// X is HORIZONTAL (0 left)
// Y is VERTICAL (0 up)
// Il root_node need to have a Layout
pub fn calculate_layout(allocator: Allocator, root_node: *Node) !void {
    const gpa = allocator;
    var row_state: RowState = .empty;
    var node_stack: std.ArrayList(*Node) = .empty;
    try node_stack.append(gpa, root_node);
    var sorted_children: std.ArrayList(*Node) = .empty;
    while (node_stack.pop()) |iter_root_node| {
        var root_state = RootState{
            .free_layout = iter_root_node.layout.?, // TODO add check
            .free_size_b = iter_root_node.size_b,
            .total_size_b = iter_root_node.size_b,
        };
        row_state.reset(root_state.free_layout);
        try sorted_children.appendSlice(gpa, iter_root_node.children.items);
        defer sorted_children.clearRetainingCapacity();
        const lessThanFn = struct {
            fn handler(_: void, lhs: *Node, rhs: *Node) bool {
                return lhs.size_b > rhs.size_b;
            }
        };
        std.sort.block(*Node, sorted_children.items, {}, lessThanFn.handler);
        std.debug.print("CAZZISSIMI\n", .{});
        for (sorted_children.items) |c| {
            std.debug.print("\t{}\n", .{c.size_b});
        }
        for (sorted_children.items) |child_node| {
            if (child_node.size_b == 0) {
                std.debug.print("Rejected zero-sized node {s}\n", .{child_node.path});
                continue;
            }
            if (!try row_state.try_insert(gpa, child_node, &root_state)) {
                // TODO: move into object?
                // Not Inserted, rejected. Row completed.
                row_state.register_layout();
                // Finished assigning layouting, clearing row
                row_state.reset(root_state.free_layout);
                if (!try row_state.try_insert(gpa, child_node, &root_state)) {
                    std.debug.print("Node lost: {s}\n", .{child_node.path});
                }
            }
            // Finished children nodes. Append to root node stack.
            if (child_node.kind == .directory) {
                // In theory it's insert to index 0. Check more.
                try node_stack.append(gpa, child_node);
            }
        }
        // Finished childrens. Register last row if not empty
        if (row_state.nodes.items.len != 0) {
            row_state.register_layout();
        }
    }
}
