const INPUT_OFFSET = 0;
const OUTPUT_OFFSET = 8;
const MEMORY_PAGES = 1;

let instance = null;

async function loadWasm() {
  const res = await fetch('ovo.wasm');
  if (!res.ok) throw new Error(`Failed to load WASM: ${res.status}`);
  const buf = await res.arrayBuffer();
  const { instance: i } = await WebAssembly.instantiate(buf, {
    env: {},
  });
  instance = i;
  return i;
}

function runForward(x1, x2) {
  if (!instance) throw new Error('WASM not loaded');
  const memory = instance.exports.memory;
  if (!memory) throw new Error('No memory export');
  const view = new DataView(memory.buffer);
  view.setFloat32(INPUT_OFFSET, x1, true);
  view.setFloat32(INPUT_OFFSET + 4, x2, true);
  instance.exports.nn_init();
  instance.exports.nn_forward(INPUT_OFFSET, OUTPUT_OFFSET);
  return view.getFloat32(OUTPUT_OFFSET, true);
}

async function main() {
  const out = document.getElementById('out');
  const runBtn = document.getElementById('run');
  const x1Input = document.getElementById('x1');
  const x2Input = document.getElementById('x2');

  try {
    await loadWasm();
    out.textContent = 'WASM loaded. Click "Run forward" to run the NN.';
  } catch (e) {
    out.className = 'err';
    out.textContent = `Error: ${e.message}`;
    return;
  }

  runBtn.addEventListener('click', () => {
    const x1 = Number(x1Input.value);
    const x2 = Number(x2Input.value);
    try {
      const y = runForward(x1, x2);
      out.className = '';
      out.textContent = `Output: ${y.toFixed(6)}`;
    } catch (e) {
      out.className = 'err';
      out.textContent = `Error: ${e.message}`;
    }
  });
}

main();
