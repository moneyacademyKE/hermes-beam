import curator
import simplifile

pub fn synthesize_skill_test() {
  let temp_dir = "test_skills_dir"
  let _ = simplifile.delete(temp_dir)

  let history = ["{\"role\": \"user\", \"content\": \"How to set up OTP?\"}"]

  let assert Ok(Nil) =
    curator.synthesize_skill(
      "session-1",
      history,
      "mock-url",
      "test-key",
      "mock-model",
      temp_dir,
    )

  // Verify file was written
  let skill_file = temp_dir <> "/mock-skill/SKILL.md"
  let assert Ok(True) = simplifile.is_file(skill_file)

  let _ = simplifile.delete(temp_dir)
}

pub fn improve_skill_test() {
  let temp_dir = "test_skills_dir"
  let _ = simplifile.delete(temp_dir)

  let assert Ok(Nil) =
    curator.improve_skill(
      "mock-skill",
      "mock content",
      "some compile errors",
      "mock-url",
      "test-key",
      "mock-model",
      temp_dir,
    )

  // Verify file was written
  let skill_file = temp_dir <> "/mock-skill/SKILL.md"
  let assert Ok(True) = simplifile.is_file(skill_file)

  let _ = simplifile.delete(temp_dir)
}
