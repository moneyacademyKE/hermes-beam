import gleeunit/should
import wasm_executor

// This test requires a compiled Wasm module to actually execute. 
// For now we test that the module linking and function export bindings compile and don't panic.
pub fn run_wasm_func_test() {
  // Pass an invalid file path and verify that we get an error, 
  // ensuring the Erlang/Elixir Wasmex interop is reachable.
  let res = wasm_executor.run_wasm_func("non_existent.wasm", "sum", [1, 2])

  // We expect an error string containing "Failed to read Wasm file"
  let is_error = case res {
    Error(_) -> True
    _ -> False
  }
  is_error |> should.be_true
}

pub fn run_wasm_stub_test() {
  let res = wasm_executor.run_wasm("test.wasm", "input")
  let is_ok = case res {
    Ok(_) -> True
    _ -> False
  }
  is_ok |> should.be_true
}
