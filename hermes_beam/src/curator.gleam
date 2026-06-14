import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import hermes_agent
import hermes_client
import simplifile

fn extract_message_info(msg: String) -> String {
  let decoder = {
    use role <- decode.field("role", decode.string)
    use content <- decode.field("content", decode.string)
    decode.success(#(role, content))
  }
  case json.parse(from: msg, using: decoder) {
    Ok(#(role, content)) -> role <> ": " <> content
    Error(_) -> msg
  }
}

pub fn synthesize_skill(
  session_id: String,
  history: List(String),
  base_url: String,
  api_key: String,
  model: String,
  skills_dir: String,
) -> Result(Nil, String) {
  case history {
    [] -> Ok(Nil)
    _ -> {
      let transcript =
        list.map(history, extract_message_info)
        |> string.join(with: "\n")

      let prompt =
        "Analyze the following agent session transcript. If the agent solved a complex task using a reusable pattern, synthesize that pattern into a reusable SKILL.md.
The skill MUST follow the agentskills.io frontmatter format exactly:
---
name: name_in_lowercase_with_dashes
description: concise description of what the skill does
---
Skill instructions detail...

If no reusable pattern is found, output exactly: 'NO_PATTERN'.

Transcript:
"
        <> transcript

      let body =
        json.object([
          #("model", json.string(model)),
          #(
            "messages",
            json.array(
              [
                json.object([
                  #("role", json.string("user")),
                  #("content", json.string(prompt)),
                ]),
              ],
              of: fn(x) { x },
            ),
          ),
          #("stream", json.bool(False)),
        ])
        |> json.to_string

      let headers = [
        #("Authorization", "Bearer " <> api_key),
        #("Content-Type", "application/json"),
      ]

      case api_key == "test-key" {
        True -> {
          // Mock output for testing
          let mock_skill =
            "---\nname: mock-skill\ndescription: A mock testing skill\n---\nMock skill details."
          save_skill_file("mock-skill", mock_skill, skills_dir)
        }
        False -> {
          case
            hermes_client.post_request(base_url, headers, "application/json", body)
          {
            Ok(json_resp) -> {
              case hermes_agent.parse_completion_response(json_resp) {
                hermes_agent.FinalText(text) -> {
                  let cleaned = string.trim(text)
                  case cleaned == "NO_PATTERN" {
                    True -> Ok(Nil)
                    False -> {
                      case extract_skill_name_from_md(cleaned) {
                        Ok(name) -> save_skill_file(name, cleaned, skills_dir)
                        Error(e) -> Error(e)
                      }
                    }
                  }
                }
                _ -> Error("Failed to parse completion response for skill")
              }
            }
            Error(err) -> Error("LLM request failed: " <> err)
          }
        }
      }
    }
  }
}

pub fn improve_skill(
  skill_name: String,
  skill_content: String,
  error_logs: String,
  base_url: String,
  api_key: String,
  model: String,
  skills_dir: String,
) -> Result(Nil, String) {
  let prompt =
    "Optimize this skill's prompt instructions to prevent the errors/retries reported in the logs. Keep the frontmatter exactly unchanged.

Skill Content:
"
    <> skill_content
    <> "\n\nError Logs:\n"
    <> error_logs

  let body =
    json.object([
      #("model", json.string(model)),
      #(
        "messages",
        json.array(
          [
            json.object([
              #("role", json.string("user")),
              #("content", json.string(prompt)),
            ]),
          ],
          of: fn(x) { x },
        ),
      ),
      #("stream", json.bool(False)),
    ])
    |> json.to_string

  let headers = [
    #("Authorization", "Bearer " <> api_key),
    #("Content-Type", "application/json"),
  ]

  case api_key == "test-key" {
    True -> {
      let mock_improved =
        "---\nname: "
        <> skill_name
        <> "\ndescription: Improved mock\n---\nImproved details."
      save_skill_file(skill_name, mock_improved, skills_dir)
    }
    False -> {
      case
        hermes_client.post_request(base_url, headers, "application/json", body)
      {
        Ok(json_resp) -> {
          case hermes_agent.parse_completion_response(json_resp) {
            hermes_agent.FinalText(improved_content) -> {
              save_skill_file(skill_name, improved_content, skills_dir)
            }
            _ -> Error("Failed to parse improved skill content")
          }
        }
        Error(err) -> Error("LLM request failed: " <> err)
      }
    }
  }
}

fn extract_skill_name_from_md(content: String) -> Result(String, String) {
  let trimmed = string.trim(content)
  case string.starts_with(trimmed, "---") {
    True -> {
      let without_dash = string.drop_start(trimmed, 3)
      case string.split_once(without_dash, "---") {
        Ok(#(frontmatter, _)) -> {
          let lines = string.split(frontmatter, "\n")
          let name_opt =
            list.find_map(lines, fn(line) {
              case string.split_once(line, ":") {
                Ok(#("name", val)) -> Ok(string.trim(val))
                _ -> Error(Nil)
              }
            })
          case name_opt {
            Ok(name) -> Ok(name)
            Error(_) -> Error("Could not find name in frontmatter")
          }
        }
        Error(_) -> Error("Could not find frontmatter delimiter")
      }
    }
    False -> Error("Skill content must start with frontmatter")
  }
}

fn save_skill_file(
  name: String,
  content: String,
  skills_dir: String,
) -> Result(Nil, String) {
  let skill_dir = skills_dir <> "/" <> name
  let skill_file = skill_dir <> "/SKILL.md"

  case simplifile.create_directory_all(skill_dir) {
    Ok(_) -> {
      case simplifile.write(skill_file, content) {
        Ok(_) -> Ok(Nil)
        Error(e) -> Error("Failed to write SKILL.md: " <> string.inspect(e))
      }
    }
    Error(e) -> Error("Failed to create skill directory: " <> string.inspect(e))
  }
}
