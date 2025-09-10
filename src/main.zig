const std = @import("std");
const vaxis = @import("vaxis");

const Event = union(enum) {
    key_press: vaxis.Key,
    winsize: vaxis.Winsize,
    focus_in,
};
fn get_selection(alloc: std.mem.Allocator, mmc_val: *MMCPack) !void {

    // Initialize a tty
    var tty: vaxis.tty.PosixTty = try vaxis.Tty.init();
    defer tty.deinit();
    // try tty.anyWriter().print("Hello!", .{});

    var vx = try vaxis.init(alloc, .{});
    defer vx.deinit(alloc, tty.anyWriter());

    var loop: vaxis.Loop(Event) = .{
        .tty = &tty,
        .vaxis = &vx,
    };
    try loop.init();
    try loop.start();
    defer loop.stop();

    try vx.enterAltScreen(tty.anyWriter());

    try vx.queryTerminal(tty.anyWriter(), 1 * std.time.ns_per_s);

    var cursor: usize = 0;
    var win_cursor: usize = 0;

    while (true) {
        var arena = std.heap.ArenaAllocator.init(alloc);
        defer arena.deinit();
        const frame_alloc = arena.allocator();

        var win = vx.window();

        const event = loop.nextEvent();
        switch (event) {
            .key_press => |key| {
                if (key.matches('c', .{ .ctrl = true }) or key.matches('q', .{})) {
                    break;
                } else if (key.matches('l', .{ .ctrl = true })) {
                    vx.queueRefresh();
                } else if (key.matches(0xe008, .{})) {
                    //up arrow
                    if (cursor == 0) {
                        cursor = mmc_val.components.len;
                        win_cursor = cursor - win.height;
                    }
                    cursor -|= 1;
                    if (cursor < win_cursor) {
                        win_cursor = cursor;
                        // } else if (cursor > win_cursor + (win.height -| 1)) {
                    }
                } else if (key.matches(0xe009, .{})) {
                    //down arrow
                    cursor +|= 1;
                    if (cursor >= mmc_val.components.len) {
                        cursor = 0;
                        win_cursor = 0;
                    } else if (cursor -| win_cursor > win.height -| 1) {
                        win_cursor += 1;
                    }
                } else if (key.matches(' ', .{})) {
                    const comp = &mmc_val.components[cursor];
                    comp.*.disabled = !comp.disabled;
                }
            },
            .winsize => |ws| {
                try vx.resize(alloc, tty.anyWriter(), ws);
                win = vx.window();
                if (cursor -| win_cursor > win.height -| 1) {
                    cursor = win_cursor + (win.height -| 1);
                }
            },
            else => {},
        }

        win.clear();

        for (mmc_val.components, 0..) |comp, row| {
            if (win_cursor > row) {
                continue;
            }
            const c: *const [3]u8 = if (comp.disabled) "[ ]" else "[x]";
            const style = if (cursor == row)
                vaxis.Style{
                    .bg = .{ .rgb = .{ 255, 255, 255 } },
                    .fg = .{ .rgb = .{ 0, 0, 0 } },
                }
            else
                vaxis.Style{
                    .bg = .{ .rgb = .{ 0, 0, 0 } },
                    .fg = .{ .rgb = .{ 255, 255, 255 } },
                };
            const result = win.printSegment(
                vaxis.Segment{
                    .text = c,
                    .style = style,
                },
                .{
                    .wrap = .none,
                    .row_offset = @truncate(row - win_cursor),
                },
            );
            const text = try std.fmt.allocPrint(frame_alloc, "{s}", .{comp.cachedName});
            _ = win.printSegment(vaxis.Segment{
                .text = text,
            }, .{
                .wrap = .none,
                .row_offset = @truncate(row - win_cursor),
                .col_offset = result.col + 1,
            });
        }

        try vx.render(tty.anyWriter());
    }
}
fn recursive_move(alloc: std.mem.Allocator, from_path: []const u8, to_path: []const u8) !void {
    const cwd = std.fs.cwd();
    var o_path_dir = try cwd.openDir(from_path, .{ .iterate = true });
    var iter = o_path_dir.iterate();
    var optional_entry = try iter.next();
    while (optional_entry) |entry| {
        const from_entry = try std.fs.path.join(alloc, &.{ from_path, entry.name });
        const to_entry = try std.fs.path.join(alloc, &.{ to_path, entry.name });
        std.debug.print("{s} => {s}\n", .{ from_entry, to_entry });
        cwd.rename(
            from_entry,
            to_entry,
        ) catch |err| switch (err) {
            error.PathAlreadyExists => {
                std.debug.print("isdir\n", .{});
                try recursive_move(alloc, from_entry, to_entry);
            },
            else => return err,
        };
        alloc.free(from_entry);
        alloc.free(to_entry);
        optional_entry = try iter.next();
    }
}
fn copy_to_output(alloc: std.mem.Allocator, file: std.fs.File, tmp: std.fs.Dir, dest: []const u8) !void {
    try std.zip.extract(tmp, file.seekableStream(), .{});
    //mv tmp files to output_dir
    try recursive_move(alloc, "tmp", dest);
}
pub fn main() !void {
    // const stdout_file = std.io.getStdOut().writer();
    var gpa = std.heap.GeneralPurposeAllocator(.{}).init;
    const alloc = gpa.allocator();
    defer _ = gpa.deinit();
    var args = try std.process.argsWithAllocator(alloc);
    _ = args.skip();
    const mmc = args.next() orelse {
        _ = try std.io.getStdErr().write("expected mmc dir");
        return;
    };
    const version_jar = args.next() orelse {
        _ = try std.io.getStdErr().write("expected mc version jar");
        return;
    };
    const version_json = args.next() orelse {
        _ = try std.io.getStdErr().write("expected mc version json");
        return;
    };
    _ = version_json;
    const output_name = args.next() orelse {
        _ = try std.io.getStdErr().write("expected output version name(no file extension)");
        return;
    };

    var cwd = std.fs.cwd();
    var mmc_path = try cwd.openDir(mmc, .{});
    defer mmc_path.close();
    const mmc_pack = try mmc_path.openFile("mmc-pack.json", .{});
    const mmc_pack_data = try mmc_pack.readToEndAlloc(alloc, 4096 * 4096);
    mmc_pack.close();
    const json = try std.json.parseFromSlice(MMCPack, alloc, mmc_pack_data, .{ .ignore_unknown_fields = true });
    defer json.deinit();
    alloc.free(mmc_pack_data);
    var mmc_val = json.value;

    try get_selection(alloc, &mmc_val);

    try cwd.makeDir(output_name);
    //extract version jar
    var version_jar_file = try cwd.openFile(version_jar, .{});
    var output_dir = try cwd.openDir(output_name, .{});

    try std.zip.extract(output_dir, version_jar_file.seekableStream(), .{});

    //go thru the pack and put the enabled jar in the output dir
    var patches = try mmc_path.openDir("patches", .{});
    var tmp = try cwd.makeOpenPath("tmp", .{ .iterate = true });
    defer tmp.close();
    for (mmc_val.components) |comp| {
        if (comp.disabled) continue;
        if (std.mem.eql(u8, comp.uid, "net.minecraft")) {
            try copy_to_output(alloc, version_jar_file, tmp, output_name);
        }
        //construct patch.json fn buffer
        const ext: [:0]const u8 = ".json";
        const ext_slice: []const u8 = ext[0..(ext.len)];
        const slices: [2][]const u8 = .{ comp.uid, ext_slice };
        var patch_file: std.fs.File = undefined;
        {
            const patch_fn = try std.mem.concat(alloc, u8, &slices);
            defer alloc.free(patch_fn);
            //open patch.json
            patch_file = patches.openFile(patch_fn, .{}) catch |e| {
                switch (e) {
                    error.FileNotFound => {
                        std.debug.print("[warn] {s} not found\n", .{patch_fn});
                        continue;
                    },
                    else => {
                        return e;
                    },
                }
            };
        }
        const data = try patch_file.readToEndAlloc(alloc, std.math.maxInt(usize));
        patch_file.close();
        //parse json format
        var parsed_patch = try std.json.parseFromSlice(Patch, alloc, data, .{ .ignore_unknown_fields = true });
        alloc.free(data);
        defer parsed_patch.deinit();
        const patch = parsed_patch.value;
        //copy jar
        var jar_mods = try mmc_path.openDir("jarmods", .{});
        defer jar_mods.close();
        for (patch.jarMods) |jar_mod| {
            var jar_mod_file = try jar_mods.openFile(jar_mod.@"MMC-filename", .{});
            defer jar_mod_file.close();
            try copy_to_output(alloc, jar_mod_file, tmp, output_name);
        }
    }
    version_jar_file.close();
    patches.close();

    try output_dir.deleteTree("META-INF");

    const ext: [:0]const u8 = ".jar";
    const ext_slice: []const u8 = ext[0..(ext.len)];
    const slices: [2][]const u8 = .{ output_name, ext_slice };
    var arena = std.heap.ArenaAllocator.init(alloc);
    const arena_alloc = arena.allocator();
    const output_jar = try std.mem.concat(arena_alloc, u8, &slices);
    // const abs_output = try output_dir.realpathAlloc(arena_alloc, ".");
    //zip up output dir (and delete it)
    const run = try std.process.Child.run(.{
        .allocator = arena_alloc,
        .argv = &.{
            "jar",
            "cf",
            output_jar,
            "-C",
            output_name,
            ".",
        },
    });
    std.debug.print("[stderr] {s}\n[stdout] {s}\n", .{ run.stderr, run.stdout });
    arena.deinit();
    //clean up
    output_dir.close();
    try cwd.deleteTree(output_name);
}

const Component = struct {
    cachedName: []u8,
    uid: []u8,
    disabled: bool = false,
};
const MMCPack = struct {
    components: []Component,
};

const JarMod = struct {
    @"MMC-displayname": []u8,
    @"MMC-filename": []u8,
};
const Patch = struct {
    jarMods: []JarMod,
};
