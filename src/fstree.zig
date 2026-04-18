const std = @import("std");
const Allocator = std.mem.Allocator;
const Dir = std.Io.Dir;

pub const FsNode = struct {
    basename: [:0]const u8,
    path: [:0]const u8,
    size_b: u64,
    kind: std.Io.File.Kind,

    children: std.ArrayList(*FsNode),
    parent: ?*FsNode,

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
pub fn create_fstree(directory: Dir, io: std.Io, allocator: Allocator) !*FsNode {
    const StackItem = struct {
        // Original (from FS)
        iter: Dir.Iterator,
        dirname_len: usize,
        // Copy (node tree)
        node: *FsNode,
    };
    var gpa = allocator;
    var stack: std.ArrayList(StackItem) = .empty;
    defer stack.deinit(gpa);
    const root_node = try gpa.create(FsNode);
    root_node.* = .{
        .basename = try gpa.dupeZ(u8, "."),
        .path = try directory.realPathFileAlloc(io, ".", gpa),
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
        while (try top.iter.next(io)) |base| {
            var dirname_len = top.dirname_len;
            // Obtain path e basename keeping in mind the previous node infos
            // using a lot of trinks about shrinking and appending to
            // an ArrayList. Optimized for low amount of allocations.
            name_buffer.shrinkRetainingCapacity(dirname_len);
            if (name_buffer.items.len != 0) {
                try name_buffer.append(gpa, std.fs.path.sep);
                dirname_len += 1;
            }
            try name_buffer.ensureUnusedCapacity(gpa, base.name.len);
            name_buffer.appendSliceAssumeCapacity(base.name);
            // Create node
            if (base.kind == .directory or base.kind == .file) {
                const new_node = try gpa.create(FsNode);
                new_node.* = .{
                    .basename = try gpa.dupeZ(u8, base.name),
                    .path = try gpa.dupeZ(u8, name_buffer.items),
                    .size_b = if (base.kind == .file) (try top.iter.reader.dir.statFile(io, base.name, .{ .follow_symlinks = false })).size else 0,
                    .kind = base.kind,
                    .children = .empty,
                    .parent = top.node,
                };
                // Report size to parents if file
                if (base.kind == .file) {
                    var parent: ?*FsNode = top.node;
                    while (parent) |pn| {
                        pn.size_b += new_node.size_b;
                        parent = pn.parent;
                    }
                }
                // Continue with node creation
                try top.node.children.append(gpa, new_node);
                if (base.kind == .directory) {
                    var new_dir = top.iter.reader.dir.openDir(io, base.name, .{ .iterate = true }) catch |err| switch (err) {
                        error.NameTooLong => unreachable, // no path sep in base.name
                        else => |e| return e,
                    };
                    // TODO: why the scope? for the errdefer?
                    {
                        errdefer new_dir.close(io);
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
            item.iter.reader.dir.close(io);
        }
    }
    return root_node;
}
