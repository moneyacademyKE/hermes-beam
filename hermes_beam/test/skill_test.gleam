import gleam/list
import gleamdb.{Datom, Rule}
import skill.{Skill}

pub fn skill_registration_and_routing_test() {
  // Define a network-routing skill
  let routing_skill =
    Skill(
      name: "network-routing",
      description: "Natively calculates paths between network nodes",
      rules: [
        // Rule 1: path(?x, ?y) :- link(?x, ?y)
        Rule(
          head: #("?x", "route/path", "?y"),
          body: [#("?x", "route/link", "?y")],
        ),
        // Rule 2: path(?x, ?y) :- path(?x, ?z), link(?z, ?y)
        Rule(
          head: #("?x", "route/path", "?y"),
          body: [#("?x", "route/path", "?z"), #("?z", "route/link", "?y")],
        ),
      ],
      facts: [
        Datom("A", "route/link", "B"),
        Datom("B", "route/link", "C"),
        Datom("C", "route/link", "D"),
      ],
    )

  // Create registry and register skill
  let registry =
    skill.new_registry()
    |> skill.register(routing_skill)

  // Compile the registry into a unified Datalog database snapshot
  let db = skill.compile_db(registry)

  // Query for path from A to D
  let path_a_d =
    gleamdb.query(db, [#("A", "route/path", "D")])

  // Query for path from B to D
  let path_b_d =
    gleamdb.query(db, [#("B", "route/path", "D")])

  // Query for path from D to A (should not exist in directed links)
  let path_d_a =
    gleamdb.query(db, [#("D", "route/path", "A")])

  // Assertions
  let assert False = list.is_empty(path_a_d)
  let assert False = list.is_empty(path_b_d)
  let assert True = list.is_empty(path_d_a)
}
