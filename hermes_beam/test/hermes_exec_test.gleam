import gleam/option.{None}
import gleam/string
import hermes_exec.{run_command}

pub fn run_command_success_test() {
  let assert Ok(#(output, status)) = run_command("echo hello_exec", 5000)
  let assert "hello_exec\n" = output
  let assert 0 = status
}

pub fn run_command_exit_code_test() {
  let assert Ok(#(_, status)) = run_command("sh -c 'exit 42'", 5000)
  let assert 42 = status
}

pub fn run_command_timeout_test() {
  let assert Error(msg) = run_command("sleep 5", 100)
  let assert "Command execution timed out after 100ms" = msg
}

pub fn terminal_env_init_and_execute_test() {
  let initial_cwd = hermes_exec.get_temp_dir()
  let env =
    hermes_exec.new_terminal_env(initial_cwd, 5000, [
      #("MY_CUSTOM_VAR", "my_value"),
      #("OPENAI_API_KEY", "should_be_stripped"),
      #("_HERMES_FORCE_OPENAI_API_KEY", "should_be_preserved"),
    ])

  let env = hermes_exec.init_session(env)
  let assert True = env.snapshot_ready

  // Test custom environment variables
  let #(env, result) = hermes_exec.execute(env, "echo $MY_CUSTOM_VAR", "", None)
  let assert Ok(#(output, 0)) = result
  let assert "my_value" = string.trim(output)

  // Test blocklisted key behavior: stripped but force-key survives
  let #(env, result) =
    hermes_exec.execute(env, "echo $OPENAI_API_KEY", "", None)
  let assert Ok(#(output2, 0)) = result
  let assert "should_be_preserved" = string.trim(output2)

  // Test navigation and CWD tracking
  let #(env, result) = hermes_exec.execute(env, "cd / && pwd", "", None)
  let assert Ok(#(_, 0)) = result
  let assert "/" = env.cwd

  hermes_exec.cleanup(env)
}
