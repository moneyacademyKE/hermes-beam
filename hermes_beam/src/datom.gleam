import gleam/option.{type Option}

pub type FilterArg {
  VarArg(String)
  IntArg(Int)
  FloatArg(Float)
  StrArg(String)
}

pub type Clause {
  Triple(entity: String, attribute: String, value: String)
  Not(Clause)
  Filter(op: String, arg1: String, arg2: FilterArg)
  ShortestPath(
    from: String,
    to: String,
    edge: String,
    path_var: String,
    cost_var: Option(String),
    max_depth: Option(Int),
  )
  Reachable(from: String, edge: String, node_var: String)
  CycleDetect(edge: String, cycle_var: String)
  TopologicalSort(edge: String, order_var: String)
  PageRank(
    entity_var: String,
    edge: String,
    rank_var: String,
    damping: Float,
    iterations: Int,
  )
  Scc(edge: String, entity_var: String, component_var: String)
}

pub type Datom {
  Datom(entity: String, attribute: String, value: String)
}

pub type Rule {
  Rule(head: #(String, String, String), body: List(Clause))
}

pub type Query {
  Query(find: List(String), where: List(Clause))
}
