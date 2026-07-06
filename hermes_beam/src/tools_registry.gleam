import constants
import gleam/dict.{type Dict}
import gleam/json
import gleam/list
import gleam/string
import gleam/option.{None, Some}

// ─── Tool Definitions ─────────────────────────────────────────────────────────

pub type ParamDef {
  ParamDef(type_: String, description: String)
}

pub type ToolDef {
  ToolDef(
    name: String,
    description: String,
    parameters: Dict(String, ParamDef),
    required: List(String),
  )
}

// ─── Core Tools ───────────────────────────────────────────────────────────────

pub fn core_tools() -> List(ToolDef) {
  [
    ToolDef(
      name: "run_command",
      description: "Execute a shell command in the sandboxed terminal environment and return its stdout/stderr output and exit code. CRITICAL: You MUST use Babashka (bb) for any task that requires scripting. DO NOT USE PYTHON.",
      parameters: dict.from_list([
        #(
          "command",
          ParamDef(
            "string",
            "The shell command to run (e.g. \"ls -la\", \"cat README.md\", \"echo hello\", \"bb -e '(+ 1 2)'\").",
          ),
        ),
      ]),
      required: ["command"],
    ),
    ToolDef(
      name: "write_file",
      description: "Write content to a file at the given absolute or relative path, overwriting it if it already exists.",
      parameters: dict.from_list([
        #("path", ParamDef("string", "The path to the file to write.")),
        #(
          "content",
          ParamDef("string", "The full content to write into the file."),
        ),
      ]),
      required: ["path", "content"],
    ),
    ToolDef(
      name: "read_file",
      description: "Read the complete contents of a file at the given path.",
      parameters: dict.from_list([
        #("path", ParamDef("string", "The path to the file to read.")),
      ]),
      required: ["path"],
    ),
    ToolDef(
      name: "semantic_search_history",
      description: "Search the conversation history using semantic embedding similarity to find conceptually related messages, even if keywords don't match.",
      parameters: dict.from_list([
        #(
          "query",
          ParamDef("string", "The search query or concept to find in history."),
        ),
      ]),
      required: ["query"],
    ),
    ToolDef(
      name: "handoff_session",
      description: "Handoff context to another session or subagent by injecting a structured context payload into their history.",
      parameters: dict.from_list([
        #(
          "target_session_id",
          ParamDef("string", "The target session ID to handoff to."),
        ),
        #(
          "handoff_context",
          ParamDef(
            "string",
            "The context or instruction summary to pass to the target session.",
          ),
        ),
      ]),
      required: ["target_session_id", "handoff_context"],
    ),
    ToolDef(
      name: "create_worktree",
      description: "Create an isolated git worktree for parallel agent work. Returns the worktree path and branch name.",
      parameters: dict.from_list([
        #("agent_id", ParamDef("string", "A unique identifier for this worktree (e.g. 'fix-auth', 'refactor-db').")),
      ]),
      required: ["agent_id"],
    ),
    ToolDef(
      name: "diff_worktree",
      description: "Show the diff of uncommitted changes in an agent's worktree.",
      parameters: dict.from_list([
        #("agent_id", ParamDef("string", "The agent ID of the worktree to diff.")),
      ]),
      required: ["agent_id"],
    ),
    ToolDef(
      name: "browser_navigate",
      description: "Navigate the browser to a URL and return the page content. Requires Chrome/Chromium installed.",
      parameters: dict.from_list([
        #("url", ParamDef("string", "The URL to navigate to.")),
      ]),
      required: ["url"],
    ),
    ToolDef(
      name: "browser_screenshot",
      description: "Take a screenshot of the current browser page.",
      parameters: dict.from_list([
        #("path", ParamDef("string", "The file path to save the screenshot to.")),
      ]),
      required: ["path"],
    ),
  ]
}

pub fn semantic_search_enabled() -> Bool {
  case constants.get_env("HERMES_ENABLE_SEMANTIC_SEARCH") {
    Some(value) -> case string.lowercase(string.trim(value)) {
      "1" | "true" | "yes" | "on" -> True
      _ -> False
    }
    None -> False
  }
}

pub fn enabled_core_tools() -> List(ToolDef) {
  core_tools()
  |> list.filter(fn(tool) {
    case tool.name {
      "semantic_search_history" -> semantic_search_enabled()
      _ -> True
    }
  })
}

pub fn core_tools_with_policy(allowed: fn(String) -> Bool) -> List(ToolDef) {
  enabled_core_tools()
  |> list.filter(fn(tool) { allowed(tool.name) })
}

// ─── Schema Generator ─────────────────────────────────────────────────────────

/// Generate the OpenAI-compatible JSON schema string for a tool.
pub fn to_json_schema(tool: ToolDef) -> String {
  let params_json =
    dict.map_values(tool.parameters, fn(_k, v) {
      json.object([
        #("type", json.string(v.type_)),
        #("description", json.string(v.description)),
      ])
    })

  let properties = json.object(dict.to_list(params_json))

  let req_list = list.map(tool.required, json.string)

  let func_obj =
    json.object([
      #("name", json.string(tool.name)),
      #("description", json.string(tool.description)),
      #(
        "parameters",
        json.object([
          #("type", json.string("object")),
          #("properties", properties),
          #("required", json.array(req_list, of: fn(x) { x })),
        ]),
      ),
    ])

  json.object([
    #("type", json.string("function")),
    #("function", func_obj),
  ])
  |> json.to_string
}

/// Helper: Auto-generate the full JSON list of schemas for the core tools.
pub fn all_core_tool_schemas() -> String {
  let schemas =
    enabled_core_tools()
    |> list.map(to_json_schema)
    |> string.join(",")
  schemas
}

pub fn all_core_tool_schemas_with_policy(allowed: fn(String) -> Bool) -> String {
  let schemas =
    core_tools_with_policy(allowed)
    |> list.map(to_json_schema)
    |> string.join(",")
  schemas
}
