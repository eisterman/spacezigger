const std = @import("std");
const Allocator = std.mem.Allocator;
const Dir = std.fs.Dir;
const fs = std.fs;

pub const Node = struct {
    basename: []const u8,
    path: []const u8,
    size_b: u64,
    kind: fs.File.Kind,

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
    // Calculate Size by iterating on all node that are files
    //   and then using the parent link to bubble up the size until
    //   you reach root.
    _ = calculate_tree_size(root_node);
    return root_node;
}

fn calculate_tree_size(node: *Node) u64 {
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
