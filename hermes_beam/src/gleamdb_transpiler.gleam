import datom.{type Datom, type Query, type Rule}
import gleam/json
import gleam/list

pub fn datoms_to_json(datoms: List(Datom)) -> json.Json {
  json.array(datoms, of: fn(d) {
    json.object([
      #("entity", json.string(d.entity)),
      #("attribute", json.string(d.attribute)),
      #("value", json.string(d.value)),
    ])
  })
}

pub fn rule_to_json(r: Rule) -> json.Json {
  let head =
    json.array(
      [json.string(r.head.0), json.string(r.head.1), json.string(r.head.2)],
      of: fn(x) { x },
    )
  let body =
    list.map(r.body, fn(c) {
      json.array(
        [json.string(c.0), json.string(c.1), json.string(c.2)],
        of: fn(x) { x },
      )
    })
  json.array([head, ..body], of: fn(x) { x })
}

pub fn rules_to_json(rules: List(Rule)) -> json.Json {
  json.array(rules, of: rule_to_json)
}

pub fn query_to_json(q: Query) -> json.Json {
  let find_json = json.array(q.find, of: json.string)
  let where_json =
    json.array(
      q.where,
      of: fn(c) {
        json.array(
          [json.string(c.0), json.string(c.1), json.string(c.2)],
          of: fn(x) { x },
        )
      },
    )
  json.object([#("find", find_json), #("where", where_json)])
}

pub fn build_payload(datoms: List(Datom), rules: List(Rule), q: Query) -> String {
  json.object([
    #("datoms", datoms_to_json(datoms)),
    #("rules", rules_to_json(rules)),
    #("query", query_to_json(q)),
  ])
  |> json.to_string
}
