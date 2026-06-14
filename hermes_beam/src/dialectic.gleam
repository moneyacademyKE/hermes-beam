import datom
import gleam/dict
import gleam/list
import gleam/result
import gleam/string
import gleamdb_client
import state_actor.{type StateActor}

pub type Contradiction {
  Contradiction(attribute: String, value1: String, value2: String)
}

pub fn detect_contradictions(
  db_conn: StateActor,
) -> Result(List(Contradiction), String) {
  case state_actor.get_all_datoms(db_conn) {
    Ok(datoms) -> {
      let q =
        datom.Query(
          find: ["?attr", "?v1", "?v2"],
          where: [
            datom.Triple("user:default", "?attr", "?v1"),
            datom.Triple("user:default", "?attr", "?v2"),
            datom.Filter("!=", "?v1", datom.VarArg("?v2")),
          ],
        )

      case gleamdb_client.run_query(datoms, [], q) {
        Ok(results) -> {
          let raw =
            list.map(results, fn(r) {
              let attr = dict.get(r, "?attr") |> result.unwrap("")
              let v1 = dict.get(r, "?v1") |> result.unwrap("")
              let v2 = dict.get(r, "?v2") |> result.unwrap("")
              Contradiction(attribute: attr, value1: v1, value2: v2)
            })
          Ok(deduplicate(raw))
        }
        Error(e) -> Error("GleamDB query error: " <> e)
      }
    }
    Error(e) -> Error("Failed to get datoms: " <> string.inspect(e))
  }
}

fn deduplicate(list: List(Contradiction)) -> List(Contradiction) {
  list.fold(list, [], fn(acc: List(Contradiction), c) {
    let exists =
      list.any(acc, fn(existing) {
        existing.attribute == c.attribute
        && {
          { existing.value1 == c.value1 && existing.value2 == c.value2 }
          || { existing.value1 == c.value2 && existing.value2 == c.value1 }
        }
      })
    case exists {
      True -> acc
      False -> [c, ..acc]
    }
  })
}
