import gleam/dict.{type Dict}
import gleam/list
import gleam/result
import gleam/string

pub type Datom {
  Datom(entity: String, attribute: String, value: String)
}

pub type Rule {
  Rule(
    head: #(String, String, String),
    body: List(#(String, String, String))
  )
}

pub opaque type Database {
  Database(datoms: List(Datom))
}

pub fn new() -> Database {
  Database([])
}

pub fn transact(db: Database, datoms: List(Datom)) -> Database {
  Database(list.append(db.datoms, datoms))
}

fn match_term(term: String, val: String, env: Dict(String, String)) -> Result(Dict(String, String), Nil) {
  case string.starts_with(term, "?") {
    True -> {
      case dict.get(env, term) {
        Ok(existing) -> {
          case existing == val {
            True -> Ok(env)
            False -> Error(Nil)
          }
        }
        Error(_) -> Ok(dict.insert(env, term, val))
      }
    }
    False -> {
      case term == val {
        True -> Ok(env)
        False -> Error(Nil)
      }
    }
  }
}

fn match_clause(clause: #(String, String, String), datom: Datom, env: Dict(String, String)) -> Result(Dict(String, String), Nil) {
  use env <- result.try(match_term(clause.0, datom.entity, env))
  use env <- result.try(match_term(clause.1, datom.attribute, env))
  use env <- result.try(match_term(clause.2, datom.value, env))
  Ok(env)
}

fn query_clause(clause: #(String, String, String), db: List(Datom), envs: List(Dict(String, String))) -> List(Dict(String, String)) {
  list.flat_map(envs, fn(env) {
    list.filter_map(db, fn(datom) {
      match_clause(clause, datom, env)
    })
  })
}

pub fn query(db: Database, clauses: List(#(String, String, String))) -> List(Dict(String, String)) {
  list.fold(clauses, [dict.new()], fn(envs, clause) {
    query_clause(clause, db.datoms, envs)
  })
}

fn instantiate_term(term: String, env: Dict(String, String)) -> String {
  case string.starts_with(term, "?") {
    True -> {
      case dict.get(env, term) {
        Ok(val) -> val
        Error(_) -> term
      }
    }
    False -> term
  }
}

fn apply_rule(rule: Rule, db: List(Datom)) -> List(Datom) {
  // We temporarily wrap db in a Database struct for the query function
  let envs = query(Database(db), rule.body)
  list.map(envs, fn(env) {
    let entity = instantiate_term(rule.head.0, env)
    let attribute = instantiate_term(rule.head.1, env)
    let value = instantiate_term(rule.head.2, env)
    Datom(entity, attribute, value)
  })
}

fn step_rules(rules: List(Rule), db: List(Datom)) -> List(Datom) {
  let new_datoms = list.flat_map(rules, fn(rule) {
    apply_rule(rule, db)
  })
  
  list.fold(new_datoms, db, fn(acc, datom) {
    case list.contains(acc, datom) {
      True -> acc
      False -> [datom, ..acc]
    }
  })
}

pub fn evaluate_rules(db: Database, rules: List(Rule)) -> Database {
  let next_datoms = step_rules(rules, db.datoms)
  case list.length(next_datoms) == list.length(db.datoms) {
    True -> db
    False -> evaluate_rules(Database(next_datoms), rules)
  }
}
