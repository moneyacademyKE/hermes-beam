import datom.{Datom}
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import simplifile
import skill.{type Skill, Skill}

fn strip_quotes(s: String) -> String {
  let trimmed = string.trim(s)
  case string.starts_with(trimmed, "\"") && string.ends_with(trimmed, "\"") {
    True -> string.slice(trimmed, 1, string.length(trimmed) - 2)
    False -> {
      case string.starts_with(trimmed, "'") && string.ends_with(trimmed, "'") {
        True -> string.slice(trimmed, 1, string.length(trimmed) - 2)
        False -> trimmed
      }
    }
  }
}

pub fn parse_skill_file(content: String) -> Result(Skill, String) {
  let trimmed = string.trim(content)
  case string.starts_with(trimmed, "---") {
    True -> {
      // Drop the leading "---" and any immediate newlines
      let without_first_dash = string.drop_start(trimmed, 3)
      case string.split_once(without_first_dash, "---") {
        Ok(#(frontmatter, body)) -> {
          let lines = string.split(frontmatter, "\n")
          let parsed =
            list.fold(lines, #(None, None), fn(acc, line) {
              let line = string.trim(line)
              case string.starts_with(line, "#") || line == "" {
                True -> acc
                False -> {
                  case string.split_once(line, ":") {
                    Ok(#(key, val)) -> {
                      let key = string.trim(key)
                      let val = strip_quotes(val)
                      case key {
                        "name" -> #(Some(val), acc.1)
                        "description" -> #(acc.0, Some(val))
                        _ -> acc
                      }
                    }
                    Error(_) -> acc
                  }
                }
              }
            })

          case parsed {
            #(Some(name), Some(description)) -> {
              let clean_body = string.trim(body)
              Ok(
                Skill(name: name, description: description, rules: [], facts: [
                  Datom(name, "skill/prompt", clean_body),
                ]),
              )
            }
            #(None, _) -> Error("Missing 'name' in frontmatter")
            #(_, None) -> Error("Missing 'description' in frontmatter")
          }
        }
        Error(_) -> Error("Missing ending frontmatter delimiter (---)")
      }
    }
    False -> Error("Skill file must start with frontmatter delimiter (---)")
  }
}

pub fn load_skills_from_dir(dir_path: String) -> Result(List(Skill), String) {
  case simplifile.read_directory(dir_path) {
    Ok(children) -> {
      let skills =
        list.filter_map(children, fn(child) {
          let child_path = dir_path <> "/" <> child
          case simplifile.is_directory(child_path) {
            Ok(True) -> {
              let skill_md_path = child_path <> "/SKILL.md"
              case simplifile.is_file(skill_md_path) {
                Ok(True) -> {
                  case simplifile.read(skill_md_path) {
                    Ok(content) -> {
                      case parse_skill_file(content) {
                        Ok(skill) -> Ok(skill)
                        Error(err) -> Error(err)
                      }
                    }
                    Error(_) -> Error("Could not read " <> skill_md_path)
                  }
                }
                _ -> Error("SKILL.md not found in " <> child_path)
              }
            }
            _ -> Error("Not a directory: " <> child_path)
          }
        })
      Ok(skills)
    }
    Error(err) ->
      Error(
        "Could not read directory " <> dir_path <> ": " <> string.inspect(err),
      )
  }
}
