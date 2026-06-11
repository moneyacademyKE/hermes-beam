import datom.{type Datom, Query, Rule}
import gleam/list
import gleamdb_client

pub fn check_permission(
  datoms: List(Datom),
  user: String,
  resource: String,
  action: String,
) -> Bool {
  let grant_str = action <> ":" <> resource

  let rules = [
    Rule(
      head: #("?user", "user/member-of-recursive", "?group"),
      body: [#("?user", "user/member-of", "?group")],
    ),
    Rule(
      head: #("?user", "user/member-of-recursive", "?group"),
      body: [
        #("?subgroup", "group/subgroup-of", "?group"),
        #("?user", "user/member-of-recursive", "?subgroup"),
      ],
    ),
  ]

  let q =
    Query(
      find: ["?group"],
      where: [
        #(user, "user/member-of-recursive", "?group"),
        #("?group", "permission/grant", grant_str),
      ],
    )

  case gleamdb_client.run_query(datoms, rules, q) {
    Ok(results) -> !list.is_empty(results)
    _ -> False
  }
}
