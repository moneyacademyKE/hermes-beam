import datom.{Datom}
import permission

pub fn permission_inheritance_test() {
  let db = [
    Datom("alice", "user/member-of", "developer"),
    Datom("bob", "user/member-of", "guest"),
    Datom("developer", "group/subgroup-of", "staff"),
    Datom("staff", "permission/grant", "read:documents"),
    Datom("developer", "permission/grant", "write:codebase"),
    Datom("guest", "permission/grant", "read:public_status"),
  ]

  let alice_read_docs =
    permission.check_permission(db, "alice", "documents", "read")
  let alice_write_code =
    permission.check_permission(db, "alice", "codebase", "write")
  let alice_write_docs =
    permission.check_permission(db, "alice", "documents", "write")

  let bob_read_docs =
    permission.check_permission(db, "bob", "documents", "read")
  let bob_read_public =
    permission.check_permission(db, "bob", "public_status", "read")

  let assert True = alice_read_docs
  let assert True = alice_write_code
  let assert False = alice_write_docs

  let assert False = bob_read_docs
  let assert True = bob_read_public
}
