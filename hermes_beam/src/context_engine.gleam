import gleam/list
import gleam/string

pub type ContextPlugin {
  ContextPlugin(name: String, execute: fn() -> String)
}

pub fn sys_info_plugin() -> ContextPlugin {
  ContextPlugin("SysInfo", fn() {
    "<context source=\"SysInfo\">\nOS: BEAM/Erlang Runtime\nPlatform: Gleam OTP\n</context>"
  })
}

pub fn execute_all(plugins: List(ContextPlugin)) -> String {
  let contexts = list.map(plugins, fn(p) { p.execute() })
  string.join(contexts, "\n\n")
}

pub fn default_plugins() -> List(ContextPlugin) {
  [sys_info_plugin()]
}
