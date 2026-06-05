import gleam/dict
import gleam/list
import gleamdb.{Datom, Rule}
import skill.{Skill}
import evolutionary
import hermes_state
import sqlight

pub fn rule_serialization_roundtrip_test() {
  let original_rule =
    Rule(
      head: #("?x", "route/path", "?y"),
      body: [#("?x", "route/path", "?z"), #("?z", "route/link", "?y")],
    )

  // Serialize
  let datoms = evolutionary.rule_to_datoms("rule/network-path", original_rule)
  
  // Assert datoms are generated
  let assert False = list.is_empty(datoms)
  
  // Deserialize
  let rules = evolutionary.datoms_to_rules(datoms)
  
  // Assert rule is roundtripped exactly
  let assert 1 = list.length(rules)
  let assert Ok(roundtripped) = list.first(rules)
  let assert "?x" = roundtripped.head.0
  let assert "route/path" = roundtripped.head.1
  let assert "?y" = roundtripped.head.2
  let assert 2 = list.length(roundtripped.body)
  let assert Ok(#("?x", "route/path", "?z")) = list.first(roundtripped.body)
}

pub fn skill_verification_loop_test() {
  let routing_skill =
    Skill(
      name: "network-routing",
      description: "Calculates paths between network nodes",
      rules: [
        Rule(
          head: #("?x", "route/path", "?y"),
          body: [#("?x", "route/link", "?y")],
        ),
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

  // Verification checks:
  // Query: route/path("A", "?dest")
  // Expected bindings: ?dest -> "B", "C", "D"
  let checks = [
    #(
      [#("A", "route/path", "?dest")],
      [
        dict.from_list([#("?dest", "B")]),
        dict.from_list([#("?dest", "C")]),
        dict.from_list([#("?dest", "D")]),
      ],
    ),
  ]

  let res = evolutionary.verify_skill(routing_skill, checks)
  
  // Assert verification succeeds
  let assert Ok(Nil) = res
}

pub fn persist_and_load_skill_test() {
  // 1. Open an in-memory SQLite connection
  let assert Ok(conn) = sqlight.open(":memory:")
  let assert Ok(Nil) = hermes_state.init_schema(conn)

  // 2. Define a skill
  let test_skill =
    Skill(
      name: "test-routing",
      description: "Routing skill for persistence testing",
      rules: [
        Rule(
          head: #("?x", "route/path", "?y"),
          body: [#("?x", "route/link", "?y")],
        ),
        Rule(
          head: #("?x", "route/path", "?y"),
          body: [#("?x", "route/path", "?z"), #("?z", "route/link", "?y")],
        ),
      ],
      facts: [
        Datom("A", "route/link", "B"),
        Datom("B", "route/link", "C"),
      ],
    )

  // 3. Persist the skill
  let assert Ok(Nil) = evolutionary.persist_skill(conn, test_skill, 1)

  // 4. Load the database snapshot
  let assert Ok(db) = hermes_state.load_database(conn)

  // 5. Query route/path from A
  let results =
    gleamdb.query(db, [
      #("A", "route/path", "?dest"),
    ])

  // 6. Assert results contain both B and C
  let assert 2 = list.length(results)
  let assert True = list.contains(results, dict.from_list([#("?dest", "B")]))
  let assert True = list.contains(results, dict.from_list([#("?dest", "C")]))
}

