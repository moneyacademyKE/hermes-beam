import gleeunit
import hermes_agent

pub fn main() -> Nil {
  gleeunit.main()
}

pub fn hello_world_test() {
  let name = "Joe"
  let greeting = "Hello, " <> name <> "!"
  let assert "Hello, Joe!" = greeting
}

pub fn extract_delta_content_openai_test() {
  let json_str = "{\"choices\":[{\"delta\":{\"content\":\"Hello choices!\"}}]}"
  let assert "Hello choices!" = hermes_agent.extract_delta_content(json_str)
}

pub fn extract_delta_content_anthropic_test() {
  let json_str = "{\"delta\":{\"text\":\"Hello text!\"}}"
  let assert "Hello text!" = hermes_agent.extract_delta_content(json_str)
}

pub fn extract_delta_content_empty_test() {
  let json_str = "{\"choices\":[{\"delta\":{}}]}"
  let assert "" = hermes_agent.extract_delta_content(json_str)
}
