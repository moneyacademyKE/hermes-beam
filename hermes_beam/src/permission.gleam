import gleam/list
import gleamdb.{type Database, Rule}

pub fn check_permission(db: Database, user: String, resource: String, action: String) -> Bool {
  let rules = [
    // Rule 1: user/member-of-recursive(?user, ?group) :- user/member-of(?user, ?group)
    Rule(
      head: #("?user", "user/member-of-recursive", "?group"),
      body: [#("?user", "user/member-of", "?group")]
    ),
    // Rule 2: user/member-of-recursive(?user, ?group) :- user/member-of-recursive(?user, ?subgroup), group/subgroup-of(?subgroup, ?group)
    Rule(
      head: #("?user", "user/member-of-recursive", "?group"),
      body: [
        #("?user", "user/member-of-recursive", "?subgroup"),
        #("?subgroup", "group/subgroup-of", "?group")
      ]
    )
  ]
  
  // Evaluate the rules to a fixed point
  let final_db = gleamdb.evaluate_rules(db, rules)
  
  // Construct the expected permission grant string, e.g. "read:documents"
  let grant_str = action <> ":" <> resource
  
  // Query to see if the user is a recursive member of a group with the permission
  let results =
    gleamdb.query(final_db, [
      #(user, "user/member-of-recursive", "?group"),
      #("?group", "permission/grant", grant_str),
    ])
  
  !list.is_empty(results)
}
