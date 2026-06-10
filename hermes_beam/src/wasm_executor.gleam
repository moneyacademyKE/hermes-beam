import gleam/io

/// Runs an exported function from a WebAssembly module with integer arguments.
/// Since WASM tool execution has been moved to the Babashka worker, this BEAM-level
/// function is now a stub that informs the caller about worker-level execution.
pub fn run_wasm_func(
  _module_path: String,
  _func: String,
  _args: List(Int),
) -> Result(List(Int), String) {
  io.println(
    "[WASM] Notice: WASM tool execution is offloaded to the Babashka worker via run_wasm_func tool.",
  )
  Error(
    "WASM execution is offloaded to the Babashka worker. Use the 'run_wasm_func' tool call in the subagent instead.",
  )
}

/// A legacy stub function to run Wasm with string input (assuming WASI or custom bindings later).
pub fn run_wasm(module_path: String, input: String) -> Result(String, String) {
  Ok(
    "STUB: WASM execution of "
    <> module_path
    <> " with input: "
    <> input
    <> " is offloaded to the Babashka worker.",
  )
}
