const std = @import("std");
const fstree = @import("fstree.zig");
const rl = @import("raylib");
const rg = @import("raygui");
const mycamera = @import("camera.zig");

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    // var gpa = std.heap.DebugAllocator(.{}).init;
    // const allocator = gpa.allocator();
    // Create the filesystem tree
    const targetdir = try std.fs.openDirAbsolute("/home/fpasqua/zig/spacezigger", .{ .iterate = true });
    const rootnode = try fstree.copywalk(targetdir, allocator);
    var stack: std.ArrayList(*fstree.Node) = .empty;
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
    // Initialize graphics
    const screenWidth = 1280;
    const screeHeight = 720;
    rl.initWindow(screenWidth, screeHeight, "SpaceZigger");
    defer rl.closeWindow();
    rl.setTargetFPS(60);
    // Main Game Loop
    while (!rl.windowShouldClose()) {
        // Draw
        rl.beginDrawing();
        defer rl.endDrawing();
        rl.clearBackground(.white);
        rl.drawRectangle(10, 10, 50, 30, .red);
    }
}

test "simple test" {
    const gpa = std.testing.allocator;
    var list: std.ArrayList(i32) = .empty;
    defer list.deinit(gpa); // Try commenting this out and see if zig detects the memory leak!
    try list.append(gpa, 42);
    try std.testing.expectEqual(@as(i32, 42), list.pop());
}
