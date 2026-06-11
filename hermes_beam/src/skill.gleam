import datom.{type Datom, type Rule, Datom, Triple}
import gleam/list
import gleam/int

pub type Skill {
  Skill(
    name: String,
    description: String,
    rules: List(Rule),
    facts: List(Datom),
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

pub fn rule_to_datoms(rule_name: String, rule: Rule) -> List(Datom) {
  let head_datoms = [
    Datom(rule_name, "rule/head_0", rule.head.0),
    Datom(rule_name, "rule/head_1", rule.head.1),
    Datom(rule_name, "rule/head_2", rule.head.2),
  ]

  let body_datoms =
    list.index_map(rule.body, fn(clause, idx) {
      let prefix = "rule/body_" <> int.to_string(idx) <> "_"
      case clause {
        Triple(e, a, v) -> [
          Datom(rule_name, prefix <> "0", e),
          Datom(rule_name, prefix <> "1", a),
          Datom(rule_name, prefix <> "2", v),
        ]
        _ -> []
      }
    })
    |> list.flatten

  list.append(head_datoms, body_datoms)
}

pub fn compile_db(registry: Registry) -> List(Datom) {
  let base_facts = list.flat_map(registry.skills, fn(skill) { skill.facts })

  let rule_datoms =
    list.flat_map(registry.skills, fn(skill) {
      list.index_map(skill.rules, fn(rule, idx) {
        let rule_name = "rule/" <> skill.name <> "/" <> int.to_string(idx)
        rule_to_datoms(rule_name, rule)
      })
      |> list.flatten
    })

  list.append(base_facts, rule_datoms)
}
