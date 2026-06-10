pub type Datom {
  Datom(entity: String, attribute: String, value: String)
}

pub type Rule {
  Rule(head: #(String, String, String), body: List(#(String, String, String)))
}
