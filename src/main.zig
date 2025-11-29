const std = @import("std");
const mw = @import("MyWalker.zig");
// const spacezigger = @import("spacezigger");

// const NodePayload = struct {
//     basename: []const u8,
//     path: []const u8,
// };

// const Node = struct {
//     data: NodePayload,
//     children: std.ArrayList(Node),

//     pub fn init(data: NodePayload) !Node {
//         const children = std.ArrayList(Node).empty;
//         return Node{ .data = data, .children = children };
//     }

//     pub fn deinit(self: *Node, allocator: std.mem.Allocator) void {
//         for (self.children.items) |*child| {
//             child.deinit(allocator);
//         }
//         self.children.deinit(allocator);
//     }
// };

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    // var gpa = std.heap.DebugAllocator(.{}).init;
    // const allocator = gpa.allocator();
    const targetdir = try std.fs.openDirAbsolute("/home/fpasqua/zig/spacezigger", .{ .iterate = true });
    const rootnode = try mw.copywalk(targetdir, allocator);
    var stack: std.ArrayList(*mw.Node) = .empty;
    try stack.append(allocator, rootnode);
    while (stack.items.len != 0) {
        const top = stack.pop().?;
        if (top.kind == .file) {
            std.debug.print("Found file: {s} {d}\n", .{ top.path, top.size_b });
        } else {
            std.debug.print("Found non-file: {s} {d}\n", .{ top.path, top.size_b });
        }
        try stack.appendSlice(allocator, top.children.items);
    }
}

test "simple test" {
    const gpa = std.testing.allocator;
    var list: std.ArrayList(i32) = .empty;
    defer list.deinit(gpa); // Try commenting this out and see if zig detects the memory leak!
    try list.append(gpa, 42);
    try std.testing.expectEqual(@as(i32, 42), list.pop());
}
