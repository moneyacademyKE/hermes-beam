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
  Database(
    datoms: List(Datom),
    attr_index: Dict(String, List(Datom))
  )
}

pub fn new() -> Database {
  Database([], dict.new())
}

fn add_to_index(idx: Dict(String, List(Datom)), datom: Datom) -> Dict(String, List(Datom)) {
  let existing = case dict.get(idx, datom.attribute) {
    Ok(lst) -> lst
    Error(_) -> []
  }
  dict.insert(idx, datom.attribute, [datom, ..existing])
}

pub fn transact(db: Database, datoms: List(Datom)) -> Database {
  let new_idx = list.fold(datoms, db.attr_index, add_to_index)
  Database(list.append(db.datoms, datoms), new_idx)
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

fn query_clause(clause: #(String, String, String), db: Database, envs: List(Dict(String, String))) -> List(Dict(String, String)) {
  list.flat_map(envs, fn(env) {
    let attr_term = clause.1
    let search_pool = case string.starts_with(attr_term, "?") {
      True -> db.datoms
      False -> {
        // Known attribute, check index!
        case dict.get(db.attr_index, attr_term) {
          Ok(matched_datoms) -> matched_datoms
          Error(_) -> []
        }
      }
    }
    list.filter_map(search_pool, fn(datom) {
      match_clause(clause, datom, env)
    })
  })
}

pub fn query(db: Database, clauses: List(#(String, String, String))) -> List(Dict(String, String)) {
  list.fold(clauses, [dict.new()], fn(envs, clause) {
    query_clause(clause, db, envs)
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

fn apply_rule(rule: Rule, db: Database) -> List(Datom) {
  // We don't need to wrap db in a Database struct anymore since it's already one!
  let envs = query(db, rule.body)
  list.map(envs, fn(env) {
    let entity = instantiate_term(rule.head.0, env)
    let attribute = instantiate_term(rule.head.1, env)
    let value = instantiate_term(rule.head.2, env)
    Datom(entity, attribute, value)
  })
}

fn step_rules(rules: List(Rule), db: Database) -> List(Datom) {
  let new_datoms = list.flat_map(rules, fn(rule) {
    apply_rule(rule, db)
  })
  
  list.filter(new_datoms, fn(datom) {
    !list.contains(db.datoms, datom)
  })
}

pub fn evaluate_rules(db: Database, rules: List(Rule)) -> Database {
  let initial_count = list.length(db.datoms)
  let new_datoms = step_rules(rules, db)
  let next_db = transact(db, new_datoms)
  
  case list.length(next_db.datoms) > initial_count {
    True -> evaluate_rules(next_db, rules)
    False -> next_db
  }
}
