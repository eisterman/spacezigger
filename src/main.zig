const std = @import("std");
const spacezigger = @import("spacezigger");

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    // var gpa = std.heap.DebugAllocator(.{}).init;
    // const allocator = gpa.allocator();
    const targetdir = try std.fs.openDirAbsolute("/home/fpasqua/zig/spacezigger", .{ .iterate = true });
    var walker = try targetdir.walk(allocator);
    while (try walker.next()) |entry| {
        const file = try entry.dir.statFile(entry.basename);
        if (file.kind == .file) {
            std.debug.print("Found file: {s} {d}\n", .{ entry.path, file.size });
        } else {
            std.debug.print("Found non-file: {s}\n", .{entry.path});
        }
    }
}

test "simple test" {
    const gpa = std.testing.allocator;
    var list: std.ArrayList(i32) = .empty;
    defer list.deinit(gpa); // Try commenting this out and see if zig detects the memory leak!
    try list.append(gpa, 42);
    try std.testing.expectEqual(@as(i32, 42), list.pop());
}
