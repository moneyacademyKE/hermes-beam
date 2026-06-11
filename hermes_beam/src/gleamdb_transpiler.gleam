import datom.{
  type Clause,
  type Datom,
  type FilterArg,
  type Query,
  type Rule,
  CycleDetect,
  Filter,
  FloatArg,
  IntArg,
  Not,
  PageRank,
  Reachable,
  Scc,
  ShortestPath,
  StrArg,
  TopologicalSort,
  Triple,
  VarArg,
}
import gleam/json
import gleam/list
import gleam/option.{None, Some}

pub fn datoms_to_json(datoms: List(Datom)) -> json.Json {
  json.array(datoms, of: fn(d) {
    json.object([
      #("entity", json.string(d.entity)),
      #("attribute", json.string(d.attribute)),
      #("value", json.string(d.value)),
    ])
  })
}

pub fn filter_arg_to_json(arg: FilterArg) -> json.Json {
  case arg {
    VarArg(v) -> json.string(v)
    IntArg(i) -> json.int(i)
    FloatArg(f) -> json.float(f)
    StrArg(s) -> json.string(s)
  }
}

pub fn clause_to_json(c: Clause) -> json.Json {
  case c {
    Triple(e, a, v) ->
      json.array(
        [json.string(e), json.string(a), json.string(v)],
        of: fn(x) { x },
      )
    Not(inner) ->
      json.array([json.string("not"), clause_to_json(inner)], of: fn(x) { x })
    Filter(op, arg1, arg2) -> {
      let expr =
        json.array(
          [json.string(op), json.string(arg1), filter_arg_to_json(arg2)],
          of: fn(x) { x },
        )
      json.array([expr], of: fn(x) { x })
    }
    ShortestPath(from, to, edge, path_var, cost_var, max_depth) -> {
      let base = [
        json.string("shortest-path"),
        json.string(from),
        json.string(to),
        json.string(edge),
        json.string(path_var),
      ]
      let with_cost = case cost_var {
        Some(cv) -> list.append(base, [json.string(cv)])
        None -> list.append(base, [json.string("_")])
      }
      let final_list = case max_depth {
        Some(md) -> list.append(with_cost, [json.int(md)])
        None -> with_cost
      }
      json.array(final_list, of: fn(x) { x })
    }
    Reachable(from, edge, node_var) -> {
      json.array(
        [
          json.string("reachable"),
          json.string(from),
          json.string(edge),
          json.string(node_var),
        ],
        of: fn(x) { x },
      )
    }
    CycleDetect(edge, cycle_var) -> {
      json.array(
        [json.string("cycle-detect"), json.string(edge), json.string(cycle_var)],
        of: fn(x) { x },
      )
    }
    TopologicalSort(edge, order_var) -> {
      json.array(
        [
          json.string("topological-sort"),
          json.string(edge),
          json.string(order_var),
        ],
        of: fn(x) { x },
      )
    }
    PageRank(entity_var, edge, rank_var, damping, iterations) -> {
      json.array(
        [
          json.string("pagerank"),
          json.string(entity_var),
          json.string(edge),
          json.string(rank_var),
          json.float(damping),
          json.int(iterations),
        ],
        of: fn(x) { x },
      )
    }
    Scc(edge, entity_var, component_var) -> {
      json.array(
        [
          json.string("scc"),
          json.string(edge),
          json.string(entity_var),
          json.string(component_var),
        ],
        of: fn(x) { x },
      )
    }
  }
}

pub fn rule_to_json(r: Rule) -> json.Json {
  let head =
    json.array(
      [json.string(r.head.0), json.string(r.head.1), json.string(r.head.2)],
      of: fn(x) { x },
    )
  let body = list.map(r.body, clause_to_json)
  json.array([head, ..body], of: fn(x) { x })
}

pub fn rules_to_json(rules: List(Rule)) -> json.Json {
  json.array(rules, of: rule_to_json)
}

pub fn query_to_json(q: Query) -> json.Json {
  let find_json = json.array(q.find, of: json.string)
  let where_json = json.array(q.where, of: clause_to_json)
  json.object([#("find", find_json), #("where", where_json)])
}

pub fn build_payload(
  datoms: List(Datom),
  rules: List(Rule),
  q: Query,
) -> String {
  json.object([
    #("datoms", datoms_to_json(datoms)),
    #("rules", rules_to_json(rules)),
    #("query", query_to_json(q)),
  ])
  |> json.to_string
}
