import gleam/list
import gleamdb.{type Database, type Rule, type Datom}

pub type Skill {
  Skill(
    name: String,
    description: String,
    rules: List(Rule),
    facts: List(Datom)
  )
}

pub opaque type Registry {
  Registry(skills: List(Skill))
}

pub fn new_registry() -> Registry {
  Registry([])
}

pub fn register(registry: Registry, skill: Skill) -> Registry {
  Registry([skill, ..registry.skills])
}

pub fn compile_db(registry: Registry) -> Database {
  // Aggregate all base facts from registered skills
  let base_facts =
    list.flat_map(registry.skills, fn(skill) { skill.facts })

  // Initialize a fresh database with base facts
  let db =
    gleamdb.new()
    |> gleamdb.transact(base_facts)

  // Aggregate all rules from registered skills
  let all_rules =
    list.flat_map(registry.skills, fn(skill) { skill.rules })

  // Evaluate rules to a fixed point
  gleamdb.evaluate_rules(db, all_rules)
}
