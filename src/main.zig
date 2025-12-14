const std = @import("std");
const fstree = @import("fstree.zig");
const layout_mod = @import("layout.zig");
const rl = @import("raylib");
const rg = @import("raygui");

pub fn main() !void {
    // const screenWidth = 600;
    // const screenHeight = 400;
    const screenWidth = 1280;
    const screenHeight = 720;
    const gpa = std.heap.page_allocator;
    // var gpa = std.heap.DebugAllocator(.{}).init;
    // const allocator = gpa.allocator();
    // Create the filesystem tree
    const targetdir = try std.fs.openDirAbsolute("/home/fpasqua/Downloads", .{ .iterate = true });
    var rootnode = try fstree.copywalk(targetdir, gpa);
    gpa.free(rootnode.basename);
    rootnode.basename = try gpa.dupeZ(u8, "Target Directory");
    _ = fstree.calculate_tree_size(rootnode);
    std.debug.print("Size Root: {}\n", .{rootnode.size_b});
    rootnode.layout = .{
        .lower_right = .{
            .x = screenWidth,
            .y = screenHeight,
        },
    };
    try layout_mod.calculate_layout(gpa, rootnode);

    rl.initWindow(screenWidth, screenHeight, "SpaceZigger");
    defer rl.closeWindow();
    rl.setTargetFPS(60);
    // Main Game Loop
    var cur_layer_stack: std.ArrayList(*fstree.Node) = .empty;
    var next_layer_stack: std.ArrayList(*fstree.Node) = .empty;
    var max_depth: i32 = 0;
    while (!rl.windowShouldClose()) {
        // Logic
        if (rl.isKeyPressed(.down) and max_depth > 0) {
            max_depth -= 1;
        } else if (rl.isKeyPressed(.up)) {
            max_depth += 1;
        }
        // Draw
        rl.beginDrawing();
        defer rl.endDrawing();
        rl.clearBackground(.white);
        // Draw rectangles
        var draw_depth: f32 = 0;
        try next_layer_stack.append(gpa, rootnode);
        defer cur_layer_stack.clearRetainingCapacity();
        defer next_layer_stack.clearRetainingCapacity();
        while (next_layer_stack.items.len != 0 and draw_depth <= @as(f32, @floatFromInt(max_depth))) {
            cur_layer_stack.clearRetainingCapacity();
            try cur_layer_stack.appendSlice(gpa, next_layer_stack.items);
            next_layer_stack.clearRetainingCapacity();
            const dir_color = rl.Color.orange.brightness(-0.1 * draw_depth);
            while (cur_layer_stack.pop()) |top| {
                // Act on childrens
                if (top.layout) |layout| {
                    // std.debug.print("Node {s} has layout\n", .{top.path});
                    // const dl = fstree.margin(layout, 2);
                    const dl = layout; // TODO: margini a livello di layout
                    const color: rl.Color = if (top.kind == .directory) dir_color else .sky_blue;
                    rl.drawRectangle(dl.upper_left.x, dl.upper_left.y, dl.width(), dl.height(), color);
                    // TODO: Fare due funzioni per disegnare file e directory.
                    // file sono sempre uguali ma con testo al centro
                    // directory disegnano il contenuto un po' piu in basso e nell'header hanno
                    // il nome della cartella.
                    // Questi orpelli RICHIEDONO che l'assegnazione del layout e la graficazione
                    // avvengano praticamente insieme.
                    // Aiuto.
                    const fontSize = 8;
                    const width = rl.measureText(top.basename, fontSize);
                    const center = dl.center();
                    if (dl.width() > width + 2 and dl.height() >= fontSize + 2) {
                        rl.drawText(top.basename, center.x - @divTrunc(width, 2), center.y - 4, fontSize, .black);
                    }
                    rl.drawRectangleLines(dl.upper_left.x, dl.upper_left.y, dl.width(), dl.height(), .black);
                } else {
                    // std.debug.print("Node {s} has no layout. Skip.\n", .{top.path});
                }
                // Append childrens to next_layer_stack
                try next_layer_stack.appendSlice(gpa, top.children.items);
            }
            draw_depth += 1;
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
