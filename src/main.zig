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
    // var gpa_allocator = std.heap.DebugAllocator(.{}).init;
    // const gpa = gpa_allocator.allocator();
    // defer _ = gpa_allocator.detectLeaks();
    // Create the filesystem tree
    const targetdir = try std.fs.openDirAbsolute("/home/fpasqua/Downloads", .{ .iterate = true });
    // const targetdir = try std.fs.openDirAbsolute("/home/fpasqua/zig/spacezigger/testdir", .{ .iterate = true });
    var root_fsnode = try fstree.create_fstree(targetdir, gpa);
    // var rootnode = try old_fstree.copywalk(targetdir, gpa);
    defer root_fsnode.deinit(gpa);
    gpa.free(root_fsnode.basename);
    root_fsnode.basename = try gpa.dupeZ(u8, "Target Directory");
    // _ = old_fstree.calculate_tree_size(rootnode);
    std.debug.print("Size Root: {}\n", .{root_fsnode.size_b});
    const base_layout: layout_mod.LayoutRect = .{
        .lower_right = .{
            .x = screenWidth,
            .y = screenHeight,
        },
    };
    const rootnode = try layout_mod.build_layout(gpa, root_fsnode, base_layout);
    defer rootnode.deinit(gpa);
    // try old_layout_mod.calculate_layout(gpa, rootnode);

    rl.initWindow(screenWidth, screenHeight, "SpaceZigger");
    defer rl.closeWindow();
    rl.setTargetFPS(60);
    // Main Game Loop
    var cur_layer_stack: std.ArrayList(*layout_mod.LayoutNode) = .empty;
    defer cur_layer_stack.deinit(gpa);
    var next_layer_stack: std.ArrayList(*layout_mod.LayoutNode) = .empty;
    defer next_layer_stack.deinit(gpa);
    var max_depth: i32 = 0;
    var name_buffer = [_]u8{0} ** 1024;
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
        var draw_depth: i32 = 0;
        try next_layer_stack.append(gpa, rootnode);
        defer cur_layer_stack.clearRetainingCapacity();
        defer next_layer_stack.clearRetainingCapacity();
        while (next_layer_stack.items.len != 0 and draw_depth <= max_depth) {
            cur_layer_stack.clearRetainingCapacity();
            try cur_layer_stack.appendSlice(gpa, next_layer_stack.items);
            next_layer_stack.clearRetainingCapacity();
            const dir_color = rl.Color.orange.brightness(-0.1 * @as(f32, @floatFromInt(draw_depth)));
            const is_last_layer = draw_depth == max_depth;
            while (cur_layer_stack.pop()) |top| {
                const color: rl.Color = if (top.fsnode.kind == .directory) dir_color else .sky_blue;
                const dl = top.box_layout;
                rl.drawRectangle(dl.upper_left.x, dl.upper_left.y, dl.width(), dl.height(), color);
                // TODO: Fare due funzioni per disegnare file e directory.
                // file sono sempre uguali ma con testo al centro
                // directory disegnano il contenuto un po' piu in basso e nell'header hanno
                // il nome della cartella.
                // Questi orpelli RICHIEDONO che l'assegnazione del layout e la graficazione
                // avvengano praticamente insieme.
                // Aiuto.
                const fontSize = 8;
                const width = rl.measureText(top.fsnode.basename, fontSize);
                if (is_last_layer or top.fsnode.kind != .directory) {
                    const center = dl.center();
                    if (dl.width() > width + 2 and dl.height() >= fontSize + 2) {
                        rl.drawText(top.fsnode.basename, center.x - @divTrunc(width, 2), center.y - 4, fontSize, .black);
                    }
                } else {
                    if (top.namebox_layout()) |namebox_layout| {
                        const text_width_available: u64 = @intCast(namebox_layout.width());
                        const text_x = namebox_layout.upper_left.x;
                        const text_y = namebox_layout.upper_left.y + 3;
                        const text_color: rl.Color = .black;
                        if (top.fsnode.basename.len <= text_width_available) {
                            rl.drawText(top.fsnode.basename, text_x, text_y, fontSize, text_color);
                        } else {
                            if (text_width_available > 3) {
                                @memcpy(name_buffer[0 .. text_width_available - 3], top.fsnode.basename[0 .. text_width_available - 3]);
                                @memset(name_buffer[text_width_available - 3 .. text_width_available], '.');
                                name_buffer[text_width_available] = 0;
                                rl.drawText(name_buffer[0..text_width_available :0], text_x, text_y, fontSize, text_color);
                            } else {
                                var bfr = "...".*;
                                bfr[text_width_available] = 0;
                                rl.drawText(bfr[0..text_width_available :0], text_x, text_y, fontSize, text_color);
                            }
                        }
                    }
                }
                rl.drawRectangleLines(dl.upper_left.x, dl.upper_left.y, dl.width(), dl.height(), .black);
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
