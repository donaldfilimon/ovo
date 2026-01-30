const std = @import("std");
const Io = std.Io;

const ovo = @import("ovo");

pub fn main(init: std.process.Init) !void {
    // Prints to stderr, unbuffered, ignoring potential errors.
    std.debug.print("All your {s} are belong to us.\n", .{"codebase"});

    // This is appropriate for anything that lives as long as the process.
    const arena: std.mem.Allocator = init.arena.allocator();

    // Accessing command line arguments:
    const args = try init.minimal.args.toSlice(arena);
    for (args) |arg| {
        std.log.info("arg: {s}", .{arg});
    }

    // In order to do I/O operations need an `Io` instance.
    const io = init.io;

    // Stdout is for the actual output of your application, for example if you
    // are implementing gzip, then only the compressed bytes should be sent to
    // stdout, not any debugging messages.
    var stdout_buffer: [1024]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const stdout_writer = &stdout_file_writer.interface;

    var stderr_buffer: [1024]u8 = undefined;
    var stderr_file_writer: Io.File.Writer = .init(.stderr(), io, &stderr_buffer);
    const stderr_writer = &stderr_file_writer.interface;

    try ovo.printAnotherMessage(stdout_writer);

    if (args.len >= 2 and std.mem.eql(u8, args[1], "train")) {
        try trainFromCsv(arena, init.io, stdout_writer, stderr_writer, args[2..]);
        try stdout_writer.flush();
        return;
    }

    // If numeric args are provided, treat them as input and run inference.
    if (args.len > 1) {
        const input = try parseFloatArgs(arena, args[1..], stderr_writer);
        const layer_sizes = [_]usize{ input.len, 4, 1 };
        var prng = std.Random.DefaultPrng.init(0x1234);
        var net = try ovo.Network.initXavier(arena, &layer_sizes, prng.random());
        defer net.deinit();
        const output = try net.forward(arena, input, ovo.activation.sigmoid);
        defer arena.free(output);
        try stdout_writer.print("NN forward -> [{d:.6}]\n", .{output[0]});
        try stdout_writer.flush();
        return;
    }

    // Demo: fixed 2-4-1 network, one forward pass
    const layer_sizes = [_]usize{ 2, 4, 1 };
    var net = try ovo.Network.init(arena, &layer_sizes);
    defer net.deinit();
    const input = [_]f32{ 0.5, -0.3 };
    const output = try net.forward(arena, &input, ovo.activation.sigmoid);
    defer arena.free(output);
    try stdout_writer.print("NN forward [0.5, -0.3] -> [{d:.6}]\n", .{output[0]});

    try stdout_writer.flush(); // Don't forget to flush!
}

fn parseFloatArgs(
    allocator: std.mem.Allocator,
    args: []const []const u8,
    stderr_writer: *Io.Writer,
) ![]f32 {
    var list: std.ArrayList(f32) = .empty;
    defer list.deinit(allocator);
    for (args) |arg| {
        const trimmed = std.mem.trim(u8, arg, " \t\r\n");
        if (trimmed.len == 0) continue;
        const v = std.fmt.parseFloat(f32, trimmed) catch {
            try stderr_writer.print("Invalid float arg: {s}\n", .{arg});
            return error.InvalidInput;
        };
        try list.append(allocator, v);
    }
    return list.toOwnedSlice(allocator);
}

fn trainFromCsv(
    allocator: std.mem.Allocator,
    io: std.Io,
    stdout_writer: *Io.Writer,
    stderr_writer: *Io.Writer,
    args: []const []const u8,
) !void {
    var batch_size: usize = 0;
    var layers_override: ?[]const usize = null;
    var positional_start: usize = 0;
    var i: usize = 0;
    while (i < args.len) {
        if (std.mem.eql(u8, args[i], "--batch")) {
            if (i + 1 >= args.len) {
                try stderr_writer.print("Missing value for --batch\n", .{});
                return error.InvalidInput;
            }
            batch_size = std.fmt.parseInt(usize, args[i + 1], 10) catch {
                try stderr_writer.print("Invalid --batch: {s}\n", .{args[i + 1]});
                return error.InvalidInput;
            };
            if (batch_size == 0) {
                try stderr_writer.print("--batch must be >= 1\n", .{});
                return error.InvalidInput;
            }
            i += 2;
            continue;
        }
        if (std.mem.eql(u8, args[i], "--layers")) {
            if (i + 1 >= args.len) {
                try stderr_writer.print("Missing value for --layers\n", .{});
                return error.InvalidInput;
            }
            var list: std.ArrayList(usize) = .empty;
            defer list.deinit(allocator);
            var part_it = std.mem.splitScalar(u8, args[i + 1], ',');
            while (part_it.next()) |part| {
                const s = std.mem.trim(u8, part, " \t");
                if (s.len == 0) continue;
                const v = std.fmt.parseInt(usize, s, 10) catch {
                    try stderr_writer.print("Invalid --layers token: {s}\n", .{s});
                    return error.InvalidInput;
                };
                try list.append(allocator, v);
            }
            if (list.items.len < 2) {
                try stderr_writer.print("--layers must have at least 2 values (e.g. 2,4,1)\n", .{});
                return error.InvalidInput;
            }
            layers_override = try std.mem.Allocator.dupe(allocator, usize, list.items);
            i += 2;
            continue;
        }
        positional_start = i;
        break;
    }
    const positional = args[positional_start..];
    if (positional.len < 2) {
        try stderr_writer.print("Usage: ovo train [--layers a,b,c] [--batch N] <file.csv> <epochs>\n", .{});
        return error.InvalidInput;
    }
    const path = positional[0];
    const epochs = std.fmt.parseInt(u32, positional[1], 10) catch {
        try stderr_writer.print("Invalid epochs: {s}\n", .{positional[1]});
        return error.InvalidInput;
    };

    const data = try std.Io.Dir.readFileAlloc(std.Io.Dir.cwd(), io, path, allocator, std.Io.Limit.limited(10 * 1024 * 1024));
    defer allocator.free(data);
    var inputs_list: std.ArrayList(f32) = .empty;
    var targets_list: std.ArrayList(f32) = .empty;
    defer inputs_list.deinit(allocator);
    defer targets_list.deinit(allocator);

    var line_it = std.mem.splitScalar(u8, data, '\n');
    var input_size: ?usize = null;
    var rows: usize = 0;
    var row_vals: std.ArrayList(f32) = .empty;
    defer row_vals.deinit(allocator);

    while (line_it.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, " \t\r");
        if (line.len == 0) continue;
        row_vals.clearRetainingCapacity();
        var col_it = std.mem.splitScalar(u8, line, ',');
        while (col_it.next()) |token_raw| {
            const token = std.mem.trim(u8, token_raw, " \t");
            if (token.len == 0) continue;
            const v = std.fmt.parseFloat(f32, token) catch {
                try stderr_writer.print("Invalid float in CSV: {s}\n", .{token});
                return error.InvalidInput;
            };
            try row_vals.append(allocator, v);
        }
        if (row_vals.items.len < 2) continue;
        if (input_size == null) {
            input_size = row_vals.items.len - 1;
        } else if (row_vals.items.len != input_size.? + 1) {
            try stderr_writer.print("CSV row has inconsistent column count\n", .{});
            return error.InvalidInput;
        }
        const in_size = input_size.?;
        try inputs_list.appendSlice(allocator, row_vals.items[0..in_size]);
        try targets_list.append(allocator, row_vals.items[in_size]);
        rows += 1;
    }
    if (rows == 0 or input_size == null) {
        try stderr_writer.print("No valid data rows found in {s}\n", .{path});
        return error.InvalidInput;
    }

    const in_size = input_size.?;
    const output_size: usize = 1;

    const layer_sizes: []const usize = if (layers_override) |layers|
        layers
    else
        &[_]usize{ in_size, 4, 1 };
    if (layer_sizes[0] != in_size or layer_sizes[layer_sizes.len - 1] != output_size) {
        try stderr_writer.print("--layers first must match CSV input cols ({d}), last must match target cols (1)\n", .{in_size});
        return error.InvalidInput;
    }

    var prng = std.Random.DefaultPrng.init(0xBEEF);
    var net = try ovo.Network.initXavier(allocator, layer_sizes, prng.random());
    defer net.deinit();

    const inputs = inputs_list.items;
    const targets = targets_list.items;
    const input_len = in_size;

    if (batch_size > 0) {
        if (rows % batch_size != 0) {
            try stderr_writer.print("Rows ({d}) not divisible by --batch ({d}); use a divisor or batch=1\n", .{ rows, batch_size });
            return error.InvalidInput;
        }
        const num_batches = rows / batch_size;
        for (0..epochs) |epoch| {
            var total_loss: f32 = 0;
            var batches_done: usize = 0;
            for (0..num_batches) |b| {
                const start = b * batch_size;
                const in_batch = inputs[start * input_len ..][0 .. batch_size * input_len];
                const t_batch = targets[start..][0 .. batch_size * output_size];
                total_loss += try ovo.trainStepMseBatch(
                    &net,
                    allocator,
                    in_batch,
                    t_batch,
                    batch_size,
                    0.1,
                    ovo.activation.sigmoid,
                    ovo.activation.sigmoidDerivative,
                );
                batches_done += 1;
            }
            const mean_loss = total_loss / @as(f32, @floatFromInt(batches_done));
            try stdout_writer.print("epoch {d}: loss {d:.6}\n", .{ epoch, mean_loss });
        }
    } else {
        for (0..epochs) |epoch| {
            var total_loss: f32 = 0;
            for (0..rows) |r| {
                const in_slice = inputs[r * input_len..][0..input_len];
                const t_slice = targets[r..][0..1];
                total_loss += try ovo.trainStepMse(
                    &net,
                    allocator,
                    in_slice,
                    t_slice,
                    0.1,
                    ovo.activation.sigmoid,
                    ovo.activation.sigmoidDerivative,
                );
            }
            const mean_loss = total_loss / @as(f32, @floatFromInt(rows));
            try stdout_writer.print("epoch {d}: loss {d:.6}\n", .{ epoch, mean_loss });
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

test "fuzz example" {
    const Context = struct {
        fn testOne(context: @This(), input: []const u8) anyerror!void {
            _ = context;
            // Try passing `--fuzz` to `zig build test` and see if it manages to fail this test case!
            try std.testing.expect(!std.mem.eql(u8, "canyoufindme", input));
        }
    };
    try std.testing.fuzz(Context{}, Context.testOne, .{});
}
