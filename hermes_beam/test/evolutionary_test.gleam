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

pub fn apply_patch_test() {
  let initial_skill =
    Skill(
      name: "patch-test",
      description: "Testing skill patches",
      rules: [
        Rule(
          head: #("?x", "route/path", "?y"),
          body: [#("?x", "route/link", "?y")],
        ),
      ],
      facts: [
        Datom("A", "route/link", "B"),
      ],
    )

  let rule_to_add =
    Rule(
      head: #("?x", "route/path", "?y"),
      body: [#("?x", "route/path", "?z"), #("?z", "route/link", "?y")],
    )

  // 1. AddRule
  let s = evolutionary.apply_patch(initial_skill, evolutionary.AddRule(rule_to_add))
  let assert 2 = list.length(s.rules)

  // 2. DeleteRule
  let s2 = evolutionary.apply_patch(s, evolutionary.DeleteRule(rule_to_add))
  let assert 1 = list.length(s2.rules)

  // 3. ReplaceRule
  let replacement_rule =
    Rule(
      head: #("?x", "route/path", "?y"),
      body: [#("?x", "route/link_two", "?y")],
    )
  let s3 =
    evolutionary.apply_patch(
      initial_skill,
      evolutionary.ReplaceRule(
        old: Rule(
          head: #("?x", "route/path", "?y"),
          body: [#("?x", "route/link", "?y")],
        ),
        new: replacement_rule,
      ),
    )
  let assert [r] = s3.rules
  let assert "route/link_two" = list.first(r.body) |> assert_ok |> fn(clause) { clause.1 }

  // 4. AddFact
  let s4 = evolutionary.apply_patch(initial_skill, evolutionary.AddFact(Datom("B", "route/link", "C")))
  let assert 2 = list.length(s4.facts)

  // 5. DeleteFact
  let s5 = evolutionary.apply_patch(s4, evolutionary.DeleteFact(Datom("A", "route/link", "B")))
  let assert 1 = list.length(s5.facts)

  // 6. ReplaceFact
  let s6 =
    evolutionary.apply_patch(
      initial_skill,
      evolutionary.ReplaceFact(
        old: Datom("A", "route/link", "B"),
        new: Datom("A", "route/link", "Z"),
      ),
    )
  let assert [f] = s6.facts
  let assert "Z" = f.value
}

fn assert_ok(res: Result(a, b)) -> a {
  let assert Ok(val) = res
  val
}

pub fn evaluate_candidate_test() {
  let test_skill =
    Skill(
      name: "eval-test",
      description: "Testing evaluation",
      rules: [
        Rule(
          head: #("?x", "route/path", "?y"),
          body: [#("?x", "route/link", "?y")],
        ),
      ],
      facts: [
        Datom("A", "route/link", "B"),
        Datom("B", "route/link", "C"),
      ],
    )

  let checks = [
    #([#("A", "route/path", "?dest")], [dict.from_list([#("?dest", "B")])]),
    #([#("B", "route/path", "?dest")], [dict.from_list([#("?dest", "C")])]),
    #([#("A", "route/path", "?dest")], [dict.from_list([#("?dest", "C")])]), // this fails under the current rules
  ]

  let score = evolutionary.evaluate_candidate(test_skill, checks)
  // 2 out of 3 checks should pass
  let assert True = score >. 0.66 && score <. 0.67
}

pub fn optimize_skill_test() {
  let test_skill =
    Skill(
      name: "opt-test",
      description: "Testing optimization",
      rules: [
        Rule(
          head: #("?x", "route/path", "?y"),
          body: [#("?x", "route/link", "?y")],
        ),
      ],
      facts: [
        Datom("A", "route/link", "B"),
        Datom("B", "route/link", "C"),
      ],
    )

  let checks = [
    #([#("A", "route/path", "B")], [dict.new()]),
    #([#("B", "route/path", "C")], [dict.new()]),
    #([#("A", "route/path", "C")], [dict.new()]),
  ]

  let rule_to_add =
    Rule(
      head: #("?x", "route/path", "?y"),
      body: [#("?x", "route/path", "?z"), #("?z", "route/link", "?y")],
    )

  let patches = [
    evolutionary.AddRule(rule_to_add),
    evolutionary.AddFact(Datom("X", "route/link", "Y")), // doesn't improve check score
  ]

  let #(optimized_skill, score) = evolutionary.optimize_skill(test_skill, patches, checks)

  // Score should be 1.0 (all checks pass)
  let assert 1.0 = score
  let assert 2 = list.length(optimized_skill.rules)
}

