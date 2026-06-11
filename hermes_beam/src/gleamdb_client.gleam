import datom.{type Datom, type Query, type Rule}
import gleam/dict.{type Dict}
import gleam/dynamic/decode
import gleam/json
import gleam/string
import hermes_exec
import simplifile
import utils
import gleamdb_transpiler

pub fn run_query(
  datoms: List(Datom),
  rules: List(Rule),
  q: Query,
) -> Result(List(Dict(String, String)), String) {
  let payload = gleamdb_transpiler.build_payload(datoms, rules, q)
  let tmp_file = "/tmp/gleamdb_q_" <> hermes_exec.generate_uuid() <> ".json"

  case simplifile.write(tmp_file, payload) {
    Ok(_) -> {
      let root_dir = case utils.get_cwd() {
        Ok(cwd) -> {
          case string.ends_with(cwd, "/hermes_beam") {
            True -> string.drop_end(cwd, 12)
            False -> cwd
          }
        }
        Error(_) -> "/Users/moe/Desktop/ayncoder"
      }
      let worker_path = root_dir <> "/babashka_workers/src/worker.clj"
      let cmd = "bb " <> worker_path <> " --datalog-query < " <> tmp_file

      let cmd_res = hermes_exec.run_command(cmd, 5000)
      let _ = simplifile.delete(tmp_file)

      case cmd_res {
        Ok(#(out, 0)) -> {
          let results_decoder = {
            use results <- decode.field(
              "results",
              decode.list(decode.dict(decode.string, decode.string)),
            )
            decode.success(results)
          }

          case json.parse(from: out, using: results_decoder) {
            Ok(res) -> Ok(res)
            Error(err) ->
              Error("Failed to parse Datalog results: " <> string.inspect(err))
          }
        }
        Ok(#(out, code)) ->
          Error(
            "Babashka worker returned non-zero exit code: "
            <> string.inspect(code)
            <> ", stdout/stderr: "
            <> out,
          )
        Error(err) -> Error("Failed to execute Babashka worker: " <> err)
      }
    }
    Error(err) ->
      Error("Failed to write temporary query payload: " <> string.inspect(err))
  }
}
