import gleam/string
import memory_plugin

pub fn memory_plugin_honcho_test() {
  let plugin = memory_plugin.honcho_adapter("test-key", "user-123")

  let assert Ok(Nil) = plugin.save_context("session-abc", "User loves OTP.")

  let assert Ok(ctx) = plugin.retrieve_context("session-abc")
  let assert True = string.contains(ctx, "User loves OTP.")
}

pub fn memory_plugin_mem0_test() {
  let plugin = memory_plugin.mem0_adapter("test-key", "user-123")

  let assert Ok(Nil) = plugin.save_context("session-abc", "User loves OTP.")

  let assert Ok(ctx) = plugin.retrieve_context("session-abc")
  let assert True = string.contains(ctx, "User loves OTP.")
}

pub fn memory_plugin_supermemory_test() {
  let plugin = memory_plugin.supermemory_adapter("test-key", "user-123")

  let assert Ok(Nil) = plugin.save_context("session-abc", "User loves OTP.")

  let assert Ok(ctx) = plugin.retrieve_context("session-abc")
  let assert True = string.contains(ctx, "User loves OTP.")
}

