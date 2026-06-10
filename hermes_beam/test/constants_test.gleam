import constants
import gleam/option.{None, Some}
import gleeunit/should

pub fn platform_test() {
  // We are running on macOS, so is_windows should be false
  constants.is_windows()
  |> should.be_false()

  // We are not on WSL
  constants.is_wsl()
  |> should.be_false()

  // We are not in a container during test execution
  constants.is_container()
  |> should.be_false()
}

pub fn env_var_test() {
  // Set a test environment variable
  constants.set_env("HERMES_TEST_VAR", "gleam_test_val")

  // Retrieve it
  constants.get_env("HERMES_TEST_VAR")
  |> should.equal(Some("gleam_test_val"))

  // Get a non-existent env variable
  constants.get_env("NON_EXISTENT_VAR_XYZ")
  |> should.equal(None)
}

pub fn home_override_test() {
  // Initial state should be no override
  constants.get_hermes_home_override()
  |> should.equal(None)

  // Set override
  let token = constants.set_hermes_home_override(Some("/tmp/custom_hermes"))
  constants.get_hermes_home_override()
  |> should.equal(Some("/tmp/custom_hermes"))

  // Reset override using token
  constants.reset_hermes_home_override(token)
  constants.get_hermes_home_override()
  |> should.equal(None)
}

pub fn platform_default_home_test() {
  let home = constants.get_user_home()
  // On macOS it should be home / .hermes
  constants.get_platform_default_hermes_home()
  |> should.equal(home <> "/.hermes")
}

pub fn hermes_home_resolution_test() {
  // Save current env
  let original_env = constants.get_env("HERMES_HOME")

  // Test when unset (falls back to platform default)
  constants.set_env("HERMES_HOME", "")
  let default_home = constants.get_platform_default_hermes_home()
  constants.get_hermes_home()
  |> should.equal(default_home)

  // Test when set
  constants.set_env("HERMES_HOME", "/custom/path")
  constants.get_hermes_home()
  |> should.equal("/custom/path")

  // Restore environment
  case original_env {
    Some(val) -> constants.set_env("HERMES_HOME", val)
    None -> constants.set_env("HERMES_HOME", "")
  }
}

pub fn reasoning_effort_test() {
  constants.parse_reasoning_effort("none")
  |> should.equal(Some(constants.ReasoningEffort(enabled: False, effort: None)))

  constants.parse_reasoning_effort("minimal")
  |> should.equal(
    Some(constants.ReasoningEffort(enabled: True, effort: Some("minimal"))),
  )

  constants.parse_reasoning_effort("HIGH")
  |> should.equal(
    Some(constants.ReasoningEffort(enabled: True, effort: Some("high"))),
  )

  constants.parse_reasoning_effort("invalid")
  |> should.equal(None)

  constants.parse_reasoning_effort("")
  |> should.equal(None)
}

pub fn display_hermes_home_test() {
  // With home override set to user home
  let user_home = constants.get_user_home()
  let token = constants.set_hermes_home_override(Some(user_home))
  constants.display_hermes_home()
  |> should.equal("~")
  constants.reset_hermes_home_override(token)

  // With home override set to a subdirectory of user home
  let token2 = constants.set_hermes_home_override(Some(user_home <> "/.hermes"))
  constants.display_hermes_home()
  |> should.equal("~/.hermes")
  constants.reset_hermes_home_override(token2)
}
