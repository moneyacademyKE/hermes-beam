import gleam/list
import semantic_search
import vector_memory

pub fn vector_memory_cosine_similarity_identical_test() {
  let v = [1.0, 0.0, 0.0]
  let sim = semantic_search.cosine_similarity(v, v)
  let assert True = float_eq(sim, 1.0)
}

pub fn vector_memory_cosine_similarity_orthogonal_test() {
  let v1 = [1.0, 0.0]
  let v2 = [0.0, 1.0]
  let sim = semantic_search.cosine_similarity(v1, v2)
  let assert True = float_eq(sim, 0.0)
}

pub fn vector_memory_cosine_similarity_zero_vector_test() {
  let sim = semantic_search.cosine_similarity([0.0, 0.0], [1.0, 1.0])
  let assert True = float_eq(sim, 0.0)
}

pub fn vector_memory_search_disabled_test() {
  let store = vector_memory.VectorStore(
    entries: [],
    index_path: "/tmp/test_vector.json",
    embedding_backend: vector_memory.Disabled,
  )
  let results = vector_memory.search(store, "test query", "test-key", limit: 5)
  let assert 0 = list.length(results)
}

pub fn vector_memory_format_empty_results_test() {
  let result = vector_memory.format_results([])
  let assert "No results found." = result
}

pub fn vector_memory_format_nonempty_results_test() {
  let results = [
    vector_memory.SearchResult(
      content: "hello world",
      session_id: "s1",
      score: 0.95,
      source: "vector",
    ),
  ]
  let formatted = vector_memory.format_results(results)
  let assert True = str_contains(formatted, "hello world")
  let assert True = str_contains(formatted, "vector")
}

pub fn vector_memory_rrf_fuse_empty_test() {
  let results = vector_memory.rrf_fuse([], [], k: 60, limit: 5)
  let assert 0 = list.length(results)
}

pub fn vector_memory_rrf_fuse_combines_test() {
  let fts = [
    vector_memory.SearchResult("doc A", "s1", 1.0, "fts"),
    vector_memory.SearchResult("doc B", "s2", 0.8, "fts"),
  ]
  let vec_results = [
    vector_memory.SearchResult("doc B", "s2", 0.9, "vector"),
    vector_memory.SearchResult("doc C", "s3", 0.7, "vector"),
  ]
  let fused = vector_memory.rrf_fuse(fts, vec_results, k: 60, limit: 10)
  let assert True = list.length(fused) >= 2
}

pub fn vector_memory_entry_count_test() {
  let store = vector_memory.VectorStore(
    entries: [],
    index_path: "/tmp/test_vector.json",
    embedding_backend: vector_memory.Disabled,
  )
  let assert 0 = vector_memory.entry_count(store)
}

fn float_eq(a: Float, b: Float) -> Bool {
  let diff = case a -. b {
    x -> case x <. 0.0 { True -> 0.0 -. x False -> x }
  }
  diff <. 0.0001
}

fn str_contains(haystack: String, needle: String) -> Bool {
  case str_find(haystack, needle) {
    ok -> True
    error -> False
  }
}

@external(erlang, "string", "find")
fn str_find(haystack: String, needle: String) -> Result(String, Nil)
