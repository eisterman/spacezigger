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

    const Self = @This();
    pub fn deinit(self: *Self, gpa: Allocator) void {
        gpa.free(self.basename);
        gpa.free(self.path);
        for (self.children.items) |c| {
            c.deinit(gpa);
        }
        self.children.deinit(gpa);
        gpa.destroy(self);
    }
};

// TODO: right no errdefer for the tree content
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
    defer stack.deinit(gpa);
    const root_node = try gpa.create(Node);
    root_node.* = .{
        .basename = try gpa.dupeZ(u8, "."),
        .path = try realpathAllocZ(directory, gpa, "."),
        .size_b = 0,
        .kind = .directory,
        .children = .empty,
        .parent = null,
    };
    errdefer root_node.deinit(gpa);
    try stack.append(allocator, .{
        .iter = directory.iterate(),
        .dirname_len = 0,
        .node = root_node,
    });
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
