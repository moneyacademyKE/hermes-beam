import gleam/option
import gleam/string
import hermes_exec

pub fn daytona_execution_test() {
  let env = hermes_exec.new_terminal_env("/tmp", 5000, [])
  let env =
    hermes_exec.TerminalEnv(
      ..env,
      target: hermes_exec.DaytonaWorkspace("test-key", "ws-123"),
    )

  let #(_new_env, result) =
    hermes_exec.execute(env, "echo hello", "/tmp", option.None)

  case result {
    Ok(#(output, status)) -> {
      let assert True = string.contains(output, "test_output")
      let assert 0 = status
    }
    Error(_) -> panic as "Expected successful mock execution"
  }
}
