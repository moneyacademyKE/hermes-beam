import gleam/int
import gleam/json
import gleam/list
import gleam/string

pub type WorktreeInfo {
  WorktreeInfo(
    branch: String,
    path: String,
    agent_id: String,
    created_at: Int,
  )
}

@external(erlang, "erlang", "system_time")
fn system_time_seconds() -> Int

@external(erlang, "os", "cmd")
fn os_cmd(cmd: String) -> String

fn run_git(cwd: String, args: List(String)) -> Result(String, String) {
  let cmd = "git -C " <> cwd <> " " <> string.join(args, " ") <> " 2>&1"
  let output = os_cmd(cmd)
  case string.contains(output, "fatal:") || string.contains(output, "error:") {
    True -> Error(output)
    False -> Ok(output)
  }
}

pub fn create_worktree(
  repo_path: String,
  agent_id: String,
) -> Result(WorktreeInfo, String) {
  let branch_name = "agent/" <> agent_id <> "-" <> int.to_string(system_time_seconds())
  let worktree_path = repo_path <> "/.worktrees/" <> agent_id

  let _ = os_cmd("mkdir -p " <> worktree_path)

  case run_git(repo_path, ["worktree", "add", "-b", branch_name, worktree_path]) {
    Ok(_) -> {
      let info = WorktreeInfo(
        branch: branch_name,
        path: worktree_path,
        agent_id: agent_id,
        created_at: system_time_seconds(),
      )
      Ok(info)
    }
    Error(err) -> {
      case run_git(repo_path, ["worktree", "add", worktree_path, "HEAD"]) {
        Ok(_) ->
          Ok(WorktreeInfo(
            branch: branch_name,
            path: worktree_path,
            agent_id: agent_id,
            created_at: system_time_seconds(),
          ))
        Error(_) -> Error("Failed to create worktree: " <> err)
      }
    }
  }
}

pub fn remove_worktree(
  repo_path: String,
  info: WorktreeInfo,
) -> Result(Nil, String) {
  case run_git(repo_path, ["worktree", "remove", "--force", info.path]) {
    Ok(_) -> {
      let _ = run_git(repo_path, ["branch", "-D", info.branch])
      Ok(Nil)
    }
    Error(err) -> Error("Failed to remove worktree: " <> err)
  }
}

pub fn list_worktrees(repo_path: String) -> Result(List(WorktreeInfo), String) {
  case run_git(repo_path, ["worktree", "list", "--porcelain"]) {
    Ok(output) -> {
      let lines = string.split(output, "\n")
      let parsed =
        lines
        |> list.filter(fn(line) { string.starts_with(line, "worktree ") })
        |> list.map(fn(line) {
          let path = string.drop_start(line, 9)
          WorktreeInfo(
            branch: "",
            path: path,
            agent_id: "",
            created_at: 0,
          )
        })
      Ok(parsed)
    }
    Error(err) -> Error(err)
  }
}

pub fn diff_worktree(
  _repo_path: String,
  info: WorktreeInfo,
) -> Result(String, String) {
  run_git(info.path, ["diff", "--stat"])
}

pub fn commit_in_worktree(
  info: WorktreeInfo,
  message: String,
) -> Result(String, String) {
  case run_git(info.path, ["add", "-A"]) {
    Ok(_) -> {
      case run_git(info.path, ["commit", "-m", message]) {
        Ok(output) -> Ok(output)
        Error(err) -> Error(err)
      }
    }
    Error(err) -> Error(err)
  }
}

pub fn merge_worktree(
  repo_path: String,
  info: WorktreeInfo,
) -> Result(String, String) {
  case run_git(repo_path, ["merge", "--no-ff", info.branch, "-m", "Merge agent worktree: " <> info.agent_id]) {
    Ok(output) -> {
      let _ = remove_worktree(repo_path, info)
      Ok(output)
    }
    Error(err) -> Error("Merge failed: " <> err)
  }
}

pub fn to_json(info: WorktreeInfo) -> String {
  json.object([
    #("branch", json.string(info.branch)),
    #("path", json.string(info.path)),
    #("agent_id", json.string(info.agent_id)),
    #("created_at", json.int(info.created_at)),
  ])
  |> json.to_string
}

pub fn tool_create_worktree(
  cwd: String,
  agent_id: String,
) -> String {
  case create_worktree(cwd, agent_id) {
    Ok(info) -> {
      json.object([
        #("status", json.string("ok")),
        #("worktree", json.string(info.path)),
        #("branch", json.string(info.branch)),
      ])
      |> json.to_string
    }
    Error(err) ->
      json.object([#("error", json.string(err))])
      |> json.to_string
  }
}

pub fn tool_diff_worktree(cwd: String, agent_id: String) -> String {
  let path = cwd <> "/.worktrees/" <> agent_id
  let info = WorktreeInfo(branch: "", path: path, agent_id: agent_id, created_at: 0)
  case diff_worktree(cwd, info) {
    Ok(diff) ->
      json.object([
        #("status", json.string("ok")),
        #("diff", json.string(diff)),
      ])
      |> json.to_string
    Error(err) ->
      json.object([#("error", json.string(err))])
      |> json.to_string
  }
}
