import datom.{type Datom}
import gleam/json
import gleam/string
import hermes_exec
import simplifile

pub fn check_permission(
  datoms: List(Datom),
  user: String,
  resource: String,
  action: String,
) -> Bool {
  let grant_str = action <> ":" <> resource

  let rules_json =
    json.array(
      [
        json.array(
          [
            json.array(
              [
                json.string("?user"),
                json.string("user/member-of-recursive"),
                json.string("?group"),
              ],
              of: fn(x) { x },
            ),
            json.array(
              [
                json.string("?user"),
                json.string("user/member-of"),
                json.string("?group"),
              ],
              of: fn(x) { x },
            ),
          ],
          of: fn(x) { x },
        ),
        json.array(
          [
            json.array(
              [
                json.string("?user"),
                json.string("user/member-of-recursive"),
                json.string("?group"),
              ],
              of: fn(x) { x },
            ),
            json.array(
              [
                json.string("?subgroup"),
                json.string("group/subgroup-of"),
                json.string("?group"),
              ],
              of: fn(x) { x },
            ),
            json.array(
              [
                json.string("?user"),
                json.string("user/member-of-recursive"),
                json.string("?subgroup"),
              ],
              of: fn(x) { x },
            ),
          ],
          of: fn(x) { x },
        ),
      ],
      of: fn(x) { x },
    )

  let query_json =
    json.object([
      #("find", json.array([json.string("?group")], of: fn(x) { x })),
      #(
        "where",
        json.array(
          [
            json.array(
              [
                json.string(user),
                json.string("user/member-of-recursive"),
                json.string("?group"),
              ],
              of: fn(x) { x },
            ),
            json.array(
              [
                json.string("?group"),
                json.string("permission/grant"),
                json.string(grant_str),
              ],
              of: fn(x) { x },
            ),
          ],
          of: fn(x) { x },
        ),
      ),
    ])

  let datoms_json =
    json.array(datoms, of: fn(d) {
      json.object([
        #("entity", json.string(d.entity)),
        #("attribute", json.string(d.attribute)),
        #("value", json.string(d.value)),
      ])
    })

  let payload =
    json.object([
      #("datoms", datoms_json),
      #("rules", rules_json),
      #("query", query_json),
    ])
    |> json.to_string

  let tmp_file = "/tmp/hermes_perm_" <> hermes_exec.generate_uuid() <> ".json"
  let _ = simplifile.write(tmp_file, payload)

  let cmd =
    "bb /Users/moe/Desktop/ayncoder/babashka_workers/src/worker.clj --datalog-query < "
    <> tmp_file
  let cmd_res = hermes_exec.run_command(cmd, 5000)

  let _ = simplifile.delete(tmp_file)

  case cmd_res {
    Ok(#(out, 0)) -> {
      !string.contains(out, "\"results\":[]")
    }
    _ -> False
  }
}
