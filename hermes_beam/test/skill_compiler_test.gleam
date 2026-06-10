import datom.{Datom}
import gleam/list
import gleam/string
import simplifile
import skill_compiler

pub fn parse_skill_file_test() {
  let content =
    "---
name: mock-skill
description: A mock skill for testing parser.
user-invocable: true
---

This is the prompt body.
With multiple lines.
"

  let assert Ok(sk) = skill_compiler.parse_skill_file(content)
  let assert "mock-skill" = sk.name
  let assert "A mock skill for testing parser." = sk.description
  let assert [] = sk.rules

  let assert [Datom("mock-skill", "skill/prompt", prompt)] = sk.facts
  let assert "This is the prompt body.\nWith multiple lines." = prompt
}

pub fn parse_skill_file_quoted_test() {
  let content =
    "---
name: \"quoted-name\"
description: 'quoted description'
---
body"

  let assert Ok(sk) = skill_compiler.parse_skill_file(content)
  let assert "quoted-name" = sk.name
  let assert "quoted description" = sk.description
  let assert [Datom("quoted-name", "skill/prompt", "body")] = sk.facts
}

pub fn parse_skill_file_no_frontmatter_test() {
  let content = "body only"
  let assert Error(_) = skill_compiler.parse_skill_file(content)
}

pub fn parse_skill_file_missing_fields_test() {
  let content =
    "---
description: Missing name
---
body"
  let assert Error(_) = skill_compiler.parse_skill_file(content)
}

pub fn load_skills_from_dir_test() {
  // Setup a temporary directory with mock skills
  let temp_dir = "./test_skills_temp"
  let assert Ok(_) = simplifile.create_directory(temp_dir)

  let skill_dir_1 = temp_dir <> "/skill1"
  let assert Ok(_) = simplifile.create_directory(skill_dir_1)
  let skill_file_1 = skill_dir_1 <> "/SKILL.md"
  let content_1 =
    "---
name: skill1
description: Description 1
---
Prompt 1"
  let assert Ok(_) = simplifile.write(skill_file_1, content_1)

  let skill_dir_2 = temp_dir <> "/skill2"
  let assert Ok(_) = simplifile.create_directory(skill_dir_2)
  let skill_file_2 = skill_dir_2 <> "/SKILL.md"
  let content_2 =
    "---
name: skill2
description: Description 2
---
Prompt 2"
  let assert Ok(_) = simplifile.write(skill_file_2, content_2)

  // A file (not directory) in the directory, to ensure we ignore it
  let ignore_file = temp_dir <> "/some_other_file.txt"
  let assert Ok(_) = simplifile.write(ignore_file, "ignore me")

  // Load and assert
  let assert Ok(skills) = skill_compiler.load_skills_from_dir(temp_dir)
  let assert 2 = list.length(skills)

  let names = list.map(skills, fn(s) { s.name }) |> list.sort(string.compare)
  let assert ["skill1", "skill2"] = names

  // Clean up
  let _ = simplifile.delete(temp_dir)
}
