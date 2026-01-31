//! WASM entry for browser: fixed [2,4,1] network, nn_init() and nn_forward(input_offset, output_offset) as byte offsets.
const std = @import("std");
const ovo = @import("ovo");

var gpa: std.heap.GeneralPurposeAllocator(.{}) = undefined;
var arena: std.heap.ArenaAllocator = undefined;
var net: ovo.Network = undefined;
var net_initialized: bool = false;

/// Initialize the network [2,4,1] with Xavier init. Call once before nn_forward.
export fn nn_init() void {
    if (net_initialized) {
        net.deinit();
        arena.deinit();
        _ = gpa.deinit();
    }
    gpa = std.heap.GeneralPurposeAllocator(.{}){};
    arena = std.heap.ArenaAllocator.init(gpa.allocator());
    const allocator = arena.allocator();
    var prng = std.Random.DefaultPrng.init(0x1234);
    net = ovo.Network.initXavier(allocator, &[_]usize{ 2, 4, 1 }, prng.random()) catch return;
    net_initialized = true;
}

/// Run forward pass. input_offset and output_offset are byte offsets into WASM linear memory.
/// Input: 2 f32 (8 bytes). Output: 1 f32 (4 bytes). Call nn_init() first.
export fn nn_forward(input_offset: u32, output_offset: u32) void {
    if (!net_initialized) return;
    const input_ptr = @as([*]const f32, @ptrFromInt(input_offset));
    const output_ptr = @as([*]f32, @ptrFromInt(output_offset));
    const input = input_ptr[0..2];
    const output_value = forwardSingleOutput(arena.allocator(), &net, input, ovo.activation.sigmoid) catch return;
    output_ptr[0] = output_value;
}

fn forwardSingleOutput(
    allocator: std.mem.Allocator,
    net_ptr: *const ovo.Network,
    input: []const f32,
    act_fn: *const fn (f32) f32,
) !f32 {
    const output = try net_ptr.forward(allocator, input, act_fn);
    defer allocator.free(output);
    return output[0];
}
