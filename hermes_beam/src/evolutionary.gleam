import datom.{type Datom, type Rule, Datom, Rule}
import gleam/dict.{type Dict}
import gleam/dynamic/decode
import gleam/int
import gleam/list
import gleam/result
import gleam/string
import skill.{type Skill, Skill}
import sqlight
import gleamdb_client

pub fn rule_to_datoms(rule_name: String, rule: Rule) -> List(Datom) {
  let head_datoms = [
    Datom(rule_name, "rule/head_0", rule.head.0),
    Datom(rule_name, "rule/head_1", rule.head.1),
    Datom(rule_name, "rule/head_2", rule.head.2),
  ]

  let body_datoms =
    list.index_map(rule.body, fn(clause, idx) {
      let prefix = "rule/body_" <> int.to_string(idx) <> "_"
      [
        Datom(rule_name, prefix <> "0", clause.0),
        Datom(rule_name, prefix <> "1", clause.1),
        Datom(rule_name, prefix <> "2", clause.2),
      ]
    })
    |> list.flatten

  list.append(head_datoms, body_datoms)
}

fn find_value(datoms: List(Datom), attr: String) -> String {
  case list.find(datoms, fn(d) { d.attribute == attr }) {
    Ok(d) -> d.value
    Error(_) -> ""
  }
}

fn extract_body(
  datoms: List(Datom),
  idx: Int,
  acc: List(#(String, String, String)),
) -> List(#(String, String, String)) {
  let e_attr = "rule/body_" <> int.to_string(idx) <> "_0"
  let a_attr = "rule/body_" <> int.to_string(idx) <> "_1"
  let v_attr = "rule/body_" <> int.to_string(idx) <> "_2"

  let has_clause = list.any(datoms, fn(d) { d.attribute == e_attr })
  case has_clause {
    True -> {
      let clause = #(
        find_value(datoms, e_attr),
        find_value(datoms, a_attr),
        find_value(datoms, v_attr),
      )
      extract_body(datoms, idx + 1, list.append(acc, [clause]))
    }
    False -> acc
  }
}

pub fn datoms_to_rules(datoms: List(Datom)) -> List(Rule) {
  let grouped =
    list.fold(datoms, dict.new(), fn(acc, datom) {
      let list_for_entity = dict.get(acc, datom.entity) |> result.unwrap([])
      dict.insert(acc, datom.entity, [datom, ..list_for_entity])
    })

  dict.values(grouped)
  |> list.filter_map(fn(entity_datoms) {
    let has_head =
      list.any(entity_datoms, fn(d) { d.attribute == "rule/head_0" })
    case has_head {
      True -> {
        let head_0 = find_value(entity_datoms, "rule/head_0")
        let head_1 = find_value(entity_datoms, "rule/head_1")
        let head_2 = find_value(entity_datoms, "rule/head_2")
        let body = extract_body(entity_datoms, 0, [])
        Ok(Rule(head: #(head_0, head_1, head_2), body: body))
      }
      False -> Error(Nil)
    }
  })
}

pub fn verify_skill(
  skill: Skill,
  checks: List(#(List(#(String, String, String)), List(Dict(String, String)))),
) -> Result(Nil, String) {
  list.try_each(checks, fn(check) {
    let #(query_clauses, expected_bindings) = check

    let vars =
      list.flat_map(query_clauses, fn(c) { [c.0, c.1, c.2] })
      |> list.filter(fn(s) { string.starts_with(s, "?") })
      |> list.unique

    let q = datom.Query(find: vars, where: query_clauses)

    case gleamdb_client.run_query(skill.facts, skill.rules, q) {
      Ok(results) -> {
        let is_empty_expected = list.is_empty(expected_bindings)
        let is_empty_actual = list.is_empty(results)

        case is_empty_expected {
          True -> {
            case is_empty_actual {
              True -> Ok(Nil)
              False -> Error("Expected empty, but got results.")
            }
          }
          False -> {
            let all_found =
              list.all(expected_bindings, fn(b) {
                list.contains(results, b)
              })
            case all_found {
              True -> Ok(Nil)
              False -> Error("Missing expected bindings.")
            }
          }
        }
      }
      Error(err) -> Error("Failed to execute query: " <> err)
    }
  })
}

pub fn persist_skill(
  conn: sqlight.Connection,
  skill: Skill,
  tx: Int,
) -> Result(Nil, sqlight.Error) {
  let rule_datoms =
    list.index_map(skill.rules, fn(rule, idx) {
      let rule_name = "rule/" <> skill.name <> "/" <> int.to_string(idx)
      rule_to_datoms(rule_name, rule)
    })
    |> list.flatten

  let all_datoms = list.append(skill.facts, rule_datoms)

  let _ = sqlight.exec("BEGIN TRANSACTION;", conn)
  let query =
    "
    INSERT OR REPLACE INTO datoms (entity, attribute, value, tx)
    VALUES (?, ?, ?, ?);
  "

  let res =
    list.try_each(all_datoms, fn(datom) {
      sqlight.query(
        query,
        on: conn,
        with: [
          sqlight.text(datom.entity),
          sqlight.text(datom.attribute),
          sqlight.text(datom.value),
          sqlight.int(tx),
        ],
        expecting: decode.dynamic,
      )
      |> result.map(fn(_) { Nil })
    })

  case res {
    Ok(_) -> {
      let _ = sqlight.exec("COMMIT;", conn)
      Ok(Nil)
    }
    Error(err) -> {
      let _ = sqlight.exec("ROLLBACK;", conn)
      Error(err)
    }
  }
}

pub type Check =
  #(List(#(String, String, String)), List(Dict(String, String)))

pub type Patch {
  AddRule(Rule)
  DeleteRule(Rule)
  ReplaceRule(old: Rule, new: Rule)
  AddFact(Datom)
  DeleteFact(Datom)
  ReplaceFact(old: Datom, new: Datom)
}

pub fn apply_patch(skill: Skill, patch: Patch) -> Skill {
  case patch {
    AddRule(rule) -> {
      let rules = case list.contains(skill.rules, rule) {
        True -> skill.rules
        False -> list.append(skill.rules, [rule])
      }
      Skill(..skill, rules: rules)
    }
    DeleteRule(rule) -> {
      let rules = list.filter(skill.rules, fn(r) { r != rule })
      Skill(..skill, rules: rules)
    }
    ReplaceRule(old, new) -> {
      let rules =
        list.map(skill.rules, fn(r) {
          case r == old {
            True -> new
            False -> r
          }
        })
      Skill(..skill, rules: rules)
    }
    AddFact(fact) -> {
      let facts = case list.contains(skill.facts, fact) {
        True -> skill.facts
        False -> list.append(skill.facts, [fact])
      }
      Skill(..skill, facts: facts)
    }
    DeleteFact(fact) -> {
      let facts = list.filter(skill.facts, fn(f) { f != fact })
      Skill(..skill, facts: facts)
    }
    ReplaceFact(old, new) -> {
      let facts =
        list.map(skill.facts, fn(f) {
          case f == old {
            True -> new
            False -> f
          }
        })
      Skill(..skill, facts: facts)
    }
  }
}

pub fn evaluate_candidate(skill: Skill, checks: List(Check)) -> Float {
  let total = list.length(checks)
  case total == 0 {
    True -> 1.0
    False -> {
      let passed =
        list.fold(checks, 0, fn(acc, check) {
          case verify_skill(skill, [check]) {
            Ok(Nil) -> acc + 1
            Error(_) -> acc
          }
        })
      int.to_float(passed) /. int.to_float(total)
    }
  }
}

pub fn optimize_skill(
  skill: Skill,
  patches: List(Patch),
  checks: List(Check),
) -> #(Skill, Float) {
  let base_score = evaluate_candidate(skill, checks)

  list.fold(patches, #(skill, base_score), fn(acc, patch) {
    let #(current_best, current_best_score) = acc
    let candidate = apply_patch(skill, patch)
    let score = evaluate_candidate(candidate, checks)

    case score >. current_best_score {
      True -> #(candidate, score)
      False -> #(current_best, current_best_score)
    }
  })
}
