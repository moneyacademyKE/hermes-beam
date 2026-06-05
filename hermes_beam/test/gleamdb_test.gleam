import gleam/dict
import gleam/list
import gleamdb.{Datom}
import permission

pub fn gleamdb_basic_query_test() {
  let db =
    gleamdb.new()
    |> gleamdb.transact([
      Datom("alice", "user/email", "alice@example.com"),
      Datom("alice", "user/status", "active"),
      Datom("bob", "user/email", "bob@example.com"),
      Datom("bob", "user/status", "suspended"),
    ])

  // Query active users
  let results =
    gleamdb.query(db, [
      #("?user", "user/status", "active"),
      #("?user", "user/email", "?email"),
    ])

  // Asserting we find exactly Alice with her email
  let assert 1 = list.length(results)
  let assert Ok(res) = list.first(results)
  let assert Ok("alice") = dict.get(res, "?user")
  let assert Ok("alice@example.com") = dict.get(res, "?email")
}

pub fn permission_inheritance_test() {
  // Setup role hierarchy and permissions:
  // Alice is in the "developer" group.
  // The "developer" group is a subgroup of "staff".
  // The "staff" group has "read" permission on "documents".
  // The "developer" group has "write" permission on "codebase".
  let db =
    gleamdb.new()
    |> gleamdb.transact([
      // Membership
      Datom("alice", "user/member-of", "developer"),
      Datom("bob", "user/member-of", "guest"),
      
      // Hierarchy (developer is a subgroup of staff)
      Datom("developer", "group/subgroup-of", "staff"),
      
      // Permissions
      Datom("staff", "permission/grant", "read:documents"),
      Datom("developer", "permission/grant", "write:codebase"),
      Datom("guest", "permission/grant", "read:public_status"),
    ])

  // Test recursive checks
  let alice_read_docs = permission.check_permission(db, "alice", "documents", "read")
  let alice_write_code = permission.check_permission(db, "alice", "codebase", "write")
  let alice_write_docs = permission.check_permission(db, "alice", "documents", "write")
  
  let bob_read_docs = permission.check_permission(db, "bob", "documents", "read")
  let bob_read_public = permission.check_permission(db, "bob", "public_status", "read")

  // Alice inherits staff permissions (read:documents) and has developer permissions (write:codebase)
  let assert True = alice_read_docs
  let assert True = alice_write_code
  let assert False = alice_write_docs

  // Bob only has read:public_status
  let assert False = bob_read_docs
  let assert True = bob_read_public
}
