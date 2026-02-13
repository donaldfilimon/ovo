pub fn meanSquaredError(predicted: f32, actual: f32) f32 {
    const delta = predicted - actual;
    return delta * delta;
}
