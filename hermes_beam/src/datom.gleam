pub type Datom {
  Datom(entity: String, attribute: String, value: String)
}

pub type Rule {
  Rule(head: #(String, String, String), body: List(#(String, String, String)))
}

pub type Query {
  Query(find: List(String), where: List(#(String, String, String)))
}
