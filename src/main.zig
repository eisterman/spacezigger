const std = @import("std");
const fstree = @import("fstree.zig");
const layout_mod = @import("layout.zig");
const rl = @import("raylib");
const rg = @import("raygui");

const MainWidgetScreen = struct {
    rootFsNode: *fstree.FsNode,
    rootLayoutNode: ?*layout_mod.LayoutNode,

    const Self = @This();
    pub fn init(io: std.Io, gpa: std.mem.Allocator, absolutePath: []const u8) !Self {
        const targetdir = try std.Io.Dir.openDirAbsolute(io, absolutePath, .{ .iterate = true });
        var root_fsnode = try fstree.create_fstree(targetdir, io, gpa);
        gpa.free(root_fsnode.basename);
        root_fsnode.basename = try gpa.dupeZ(u8, "Target Directory");
        // _ = old_fstree.calculate_tree_size(rootnode);
        return .{
            .rootFsNode = root_fsnode,
            .rootLayoutNode = null,
        };
    }

    pub fn refreshLayout(self: *Self, gpa: std.mem.Allocator, selFsNode: *fstree.FsNode, width: i32, height: i32) !void {
        if (self.rootLayoutNode) |layoutNode| {
            layoutNode.deinit(gpa);
        }
        const base_layout: layout_mod.LayoutRect = .{
            .lower_right = .{
                .x = width,
                .y = height,
            },
        };
        const rootnode = try layout_mod.build_layout(gpa, selFsNode, base_layout);
        self.rootLayoutNode = rootnode;
    }

    pub fn deinit(self: *Self, gpa: std.mem.Allocator) void {
        if (self.rootLayoutNode) |layoutNode| {
            layoutNode.deinit(gpa);
        }
        self.rootFsNode.deinit(gpa);
    }
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    // var gpa_allocator = std.heap.DebugAllocator(.{}).init;
    // const gpa = gpa_allocator.allocator();
    // defer _ = gpa_allocator.detectLeaks();
    // Create the filesystem tree
    const targetdir = "/home/fpasqua/Downloads";
    // const targetdir = "/home/fpasqua/zig/spacezigger/testdir";
    var mainWidgetScreen = try MainWidgetScreen.init(init.io, init.gpa, targetdir);
    defer mainWidgetScreen.deinit(gpa);
    // _ = old_fstree.calculate_tree_size(rootnode);

    rl.setConfigFlags(.{ .window_resizable = true });
    rl.initWindow(1280, 720, "SpaceZigger");
    defer rl.closeWindow();
    rl.setTargetFPS(60);
    // Main Game Loop
    try mainWidgetScreen.refreshLayout(gpa, mainWidgetScreen.rootFsNode, rl.getScreenWidth(), rl.getScreenHeight());
    var cur_layer_stack: std.ArrayList(*layout_mod.LayoutNode) = .empty;
    defer cur_layer_stack.deinit(gpa);
    var next_layer_stack: std.ArrayList(*layout_mod.LayoutNode) = .empty;
    defer next_layer_stack.deinit(gpa);
    var max_depth: i32 = 1;
    var name_buffer = [_]u8{0} ** 1024;
    var focusFsNode = mainWidgetScreen.rootLayoutNode.?.fsnode;
    while (!rl.windowShouldClose()) {
        // Logic
        var refreshLayout = false;
        if (rl.isKeyPressed(.down) and max_depth > 0) {
            max_depth -= 1;
        } else if (rl.isKeyPressed(.up)) {
            max_depth += 1;
        }
        if (rl.isWindowResized()) {
            refreshLayout = true;
        }
        if (rl.isMouseButtonReleased(.right)) {
            refreshLayout = true;
            const mousePos = rl.getMousePosition();
            var scanDepth: i32 = 0;
            var scanNode = mainWidgetScreen.rootLayoutNode.?;
            while (scanDepth < max_depth) {
                for (scanNode.children.items) |child| {
                    const xmin: f32 = @floatFromInt(child.box_layout.upper_left.x);
                    const xmax: f32 = @floatFromInt(child.box_layout.lower_right.x);
                    const ymin: f32 = @floatFromInt(child.box_layout.upper_left.y);
                    const ymax: f32 = @floatFromInt(child.box_layout.lower_right.y);
                    if (xmin <= mousePos.x and mousePos.x <= xmax and ymin <= mousePos.y and mousePos.y <= ymax) {
                        if (child.fsnode.kind == .directory) {
                            scanNode = child;
                        }
                        break;
                    }
                }
                scanDepth += 1;
            }
            if (scanNode.fsnode.kind == .directory) {
                std.debug.print("Change focus to '{s}'\n", .{scanNode.fsnode.path});
                focusFsNode = scanNode.fsnode;
                max_depth = 1;
            }
        } else if (rl.isKeyReleased(.h)) {
            focusFsNode = mainWidgetScreen.rootFsNode;
            refreshLayout = true;
        } else if (rl.isKeyReleased(.b)) {
            if (focusFsNode.parent) |parent| {
                focusFsNode = parent;
                refreshLayout = true;
                max_depth += 1;
            }
        }
        if (refreshLayout) {
            std.debug.print("Reloading layout...\n", .{});
            try mainWidgetScreen.refreshLayout(gpa, focusFsNode, rl.getScreenWidth(), rl.getScreenHeight());
        }
        // Draw
        rl.beginDrawing();
        defer rl.endDrawing();
        rl.clearBackground(.white);
        // Draw rectangles
        var draw_depth: i32 = 0;
        try next_layer_stack.append(gpa, mainWidgetScreen.rootLayoutNode.?);
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
