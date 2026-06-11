import datom.{Datom, Query, Rule}
import gleam/dict
import gleam/json
import gleamdb_transpiler
import gleamdb_client

pub fn transpiler_datoms_test() {
  let datoms = [
    Datom("A", "route/link", "B"),
  ]
  let json_str = json.to_string(gleamdb_transpiler.datoms_to_json(datoms))
  let assert True = json_str == "[{\"entity\":\"A\",\"attribute\":\"route/link\",\"value\":\"B\"}]"
}

pub fn transpiler_rule_test() {
  let r = Rule(
    head: #("?x", "route-path", "?y"),
    body: [#("?x", "route/link", "?y")],
  )
  let json_str = json.to_string(gleamdb_transpiler.rule_to_json(r))
  let assert True = json_str == "[[\"?x\",\"route-path\",\"?y\"],[\"?x\",\"route/link\",\"?y\"]]"
}

pub fn transpiler_query_test() {
  let q = Query(
    find: ["?y"],
    where: [#("?x", "route/link", "?y")],
  )
  let json_str = json.to_string(gleamdb_transpiler.query_to_json(q))
  let assert True = json_str == "{\"find\":[\"?y\"],\"where\":[[\"?x\",\"route/link\",\"?y\"]]}"
}

pub fn client_query_execution_test() {
  let datoms = [
    Datom("A", "route/link", "B"),
    Datom("B", "route/link", "C"),
  ]
  let rules = [
    Rule(
      head: #("?x", "route-path", "?y"),
      body: [#("?x", "route/link", "?y")],
    ),
    Rule(
      head: #("?x", "route-path", "?z"),
      body: [
        #("?x", "route/link", "?y"),
        #("?y", "route-path", "?z"),
      ],
    ),
  ]
  let q = Query(
    find: ["?y"],
    where: [#("A", "route-path", "?y")],
  )

  let res = gleamdb_client.run_query(datoms, rules, q)
  let assert Ok(results) = res
  let assert True = results == [
    dict.from_list([#("?y", "B")]),
    dict.from_list([#("?y", "C")]),
  ]
}
