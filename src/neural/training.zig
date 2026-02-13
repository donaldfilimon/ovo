const layers = @import("layers.zig");

pub fn trainStep(layer: *layers.DenseLayer, input: f32, target: f32, learning_rate: f32) f32 {
    const predicted = layer.apply(input);
    const delta = predicted - target;
    layer.weight -= learning_rate * delta * input;
    layer.bias -= learning_rate * delta;
    return delta;
}
