# Ovo

A small feedforward neural network library and CLI in Zig.

## Requirements

- [Zig](https://ziglang.org/) 0.16.x (see `.zigversion`)

## Build

```bash
zig build
zig build test
```

## CLI

### Run demo (2-4-1 network, one forward pass)

```bash
zig build run
```

### Inference (input features as arguments)

```bash
zig build run -- 0.5 -0.3
# NN forward -> [0.xxxxxx]
```

### Train from CSV

CSV format: one row per sample, last column is the target; all other columns are inputs. All values are floats.

```bash
zig build run -- train test_data.csv 10
```

Options:

- `--layers a,b,c` — network architecture (e.g. `2,4,1`). First must match input columns, last must match target columns (1 for regression).
- `--batch N` — minibatch size (default: 1, i.e. per-sample updates).

Example:

```bash
zig build run -- train --layers 2,4,1 --batch 2 test_data.csv 100
```

## WebAssembly

Build the WASM module and demo assets:

```bash
zig build wasm
```

Output is in `zig-out/wasm/` (`.wasm`, `index.html`, `app.js`). Serve that directory and open `index.html` in a browser. The demo uses a fixed [2,4,1] network with Xavier init and sigmoid; `nn_init()` and `nn_forward(input_offset, output_offset)` are exported for use from JavaScript.

## Library usage

Add this package as a dependency in `build.zig.zon` and in `build.zig`, then:

```zig
const ovo = @import("ovo");

// Create a network (Xavier init, 2-4-1)
var prng = std.Random.DefaultPrng.init(seed);
var net = try ovo.Network.initXavier(allocator, &[_]usize{ 2, 4, 1 }, prng.random());
defer net.deinit();

// Forward pass
const output = try net.forward(allocator, &input, ovo.activation.sigmoid);
defer allocator.free(output);

// Training step (MSE, single sample or batch)
const loss_val = try ovo.trainStepMse(net, allocator, &input, &target, 0.1,
    ovo.activation.sigmoid, ovo.activation.sigmoidDerivative);

// Save / load
try net.save(writer);
var loaded = try ovo.Network.load(allocator, reader);
defer loaded.deinit();
```

## Modules

| Module        | Description                                      |
|---------------|--------------------------------------------------|
| `ovo.network` | `Network`, `Gradients`, forward, training steps  |
| `ovo.layer`   | Layer offset/count helpers for weights and biases |
| `ovo.activation` | Sigmoid, ReLU, tanh, leaky ReLU, softmax + derivatives |
| `ovo.loss`    | MSE, binary/cross-entropy + gradients            |
| `ovo.csv`     | CSV parsing for training data                    |
| `ovo.cli`     | CLI helpers                                      |

## License

See repository.
