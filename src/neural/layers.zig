pub const DenseLayer = struct {
    weight: f32,
    bias: f32 = 0.0,

    pub fn apply(self: DenseLayer, input: f32) f32 {
        return (input * self.weight) + self.bias;
    }
};
