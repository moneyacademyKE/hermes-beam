import gleeunit/should
import gleam/option.{Some, None}
import gleam/dynamic
import gleam/string
import simplifile
import utils

@external(erlang, "gleam_stdlib", "identity")
@external(javascript, "../../../gleam_stdlib.mjs", "identity")
fn dynamic_from(a: a) -> dynamic.Dynamic

pub fn is_truthy_value_test() {
  utils.is_truthy_value(dynamic_from(True), False)
  |> should.equal(True)

  utils.is_truthy_value(dynamic_from(False), True)
  |> should.equal(False)

  utils.is_truthy_value(dynamic_from("true"), False)
  |> should.equal(True)

  utils.is_truthy_value(dynamic_from("yes"), False)
  |> should.equal(True)

  utils.is_truthy_value(dynamic_from("on"), False)
  |> should.equal(True)

  utils.is_truthy_value(dynamic_from("1"), False)
  |> should.equal(True)

  utils.is_truthy_value(dynamic_from("off"), True)
  |> should.equal(False)

  utils.is_truthy_value(dynamic_from(Nil), True)
  |> should.equal(True)
}

pub fn normalize_proxy_url_test() {
  utils.normalize_proxy_url(None)
  |> should.equal(None)

  utils.normalize_proxy_url(Some(""))
  |> should.equal(None)

  utils.normalize_proxy_url(Some("socks://127.0.0.1:1080"))
  |> should.equal(Some("socks5://127.0.0.1:1080"))

  utils.normalize_proxy_url(Some("http://127.0.0.1:8080"))
  |> should.equal(Some("http://127.0.0.1:8080"))
}

pub fn base_url_hostname_test() {
  utils.base_url_hostname("https://api.openai.com/v1")
  |> should.equal("api.openai.com")

  utils.base_url_hostname("api.openai.com/v1")
  |> should.equal("api.openai.com")

  utils.base_url_hostname("")
  |> should.equal("")
}

pub fn base_url_host_matches_test() {
  utils.base_url_host_matches("https://api.moonshot.ai/v1", "moonshot.ai")
  |> should.equal(True)

  utils.base_url_host_matches("https://moonshot.ai", "moonshot.ai")
  |> should.equal(True)

  utils.base_url_host_matches("https://evil.com/moonshot.ai/v1", "moonshot.ai")
  |> should.equal(False)

  utils.base_url_host_matches("https://moonshot.ai.evil/v1", "moonshot.ai")
  |> should.equal(False)
}

pub fn atomic_json_write_test() {
  let temp_dir = "test_temp_json"
  let _ = simplifile.create_directory_all(temp_dir)
  let filepath = temp_dir <> "/test.json"

  // Create a structured dynamic object
  let test_data = utils.YamlMap([
    #("key", utils.YamlString("value")),
    #("nested", utils.YamlMap([
      #("number", utils.YamlInt(123))
    ]))
  ])

  // Write it
  let write_result = utils.atomic_json_write(filepath, test_data, Some(420)) // 0o644 is 420 in decimal
  write_result |> should.equal(Ok(Nil))

  // Read it and verify
  let assert Ok(content) = simplifile.read(filepath)
  let _ = simplifile.delete(filepath)
  let _ = simplifile.delete(temp_dir)

  string.contains(content, "key") |> should.be_true
  string.contains(content, "value") |> should.be_true
}

pub fn atomic_yaml_write_test() {
  let temp_dir = "test_temp_yaml"
  let _ = simplifile.create_directory_all(temp_dir)
  let filepath = temp_dir <> "/test.yaml"

  // Create a structured object
  let test_data = utils.YamlMap([
    #("key", utils.YamlString("value")),
    #("nested", utils.YamlMap([
      #("number", utils.YamlInt(123))
    ]))
  ])

  // Write it
  let write_result = utils.atomic_yaml_write(filepath, test_data, Some(420))
  write_result |> should.equal(Ok(Nil))

  // Read it and verify
  let assert Ok(content) = simplifile.read(filepath)
  let _ = simplifile.delete(filepath)
  let _ = simplifile.delete(temp_dir)

  string.contains(content, "key: value") |> should.be_true
  string.contains(content, "number: 123") |> should.be_true
}
