import constants
import gleam/bit_array
import gleam/dict.{type Dict}
import gleam/dynamic/decode
import gleam/float
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import semantic_search
import simplifile

pub type EmbeddingEntry {
  EmbeddingEntry(
    id: String,
    content: String,
    embedding: List(Float),
    session_id: String,
    timestamp: Int,
  )
}

pub type SearchResult {
  SearchResult(
    content: String,
    session_id: String,
    score: Float,
    source: String,
  )
}

pub type VectorStore {
  VectorStore(
    entries: List(EmbeddingEntry),
    index_path: String,
    embedding_backend: EmbeddingBackend,
  )
}

pub type EmbeddingBackend {
  ApiEmbeddings
  HashEmbeddings
  Disabled
}

@external(erlang, "erlang", "system_time")
fn system_time_seconds() -> Int

pub fn backend_from_env() -> EmbeddingBackend {
  case constants.get_env("HERMES_VECTOR_BACKEND") {
    Some(b) -> {
      case string.lowercase(string.trim(b)) {
        "api" -> ApiEmbeddings
        "hash" -> HashEmbeddings
        "disabled" | "none" | "off" -> Disabled
        _ -> ApiEmbeddings
      }
    }
    None -> ApiEmbeddings
  }
}

pub fn index_path() -> String {
  constants.path_join(constants.get_hermes_home(), "vector_index.json")
}

pub fn new() -> VectorStore {
  let path = index_path()
  let backend = backend_from_env()
  let entries = case load_index(path) {
    Ok(loaded) -> loaded
    Error(_) -> []
  }
  VectorStore(entries: entries, index_path: path, embedding_backend: backend)
}

pub fn load_index(path: String) -> Result(List(EmbeddingEntry), String) {
  case simplifile.read(path) {
    Ok(content) -> {
      let decoder = decode_entry_list()
      case json.parse(from: content, using: decoder) {
        Ok(entries) -> Ok(entries)
        Error(_) -> Ok([])
      }
    }
    Error(_) -> Ok([])
  }
}

pub fn save_index(store: VectorStore) -> Result(Nil, String) {
  let entries_json =
    store.entries
    |> list.map(fn(entry) {
      json.object([
        #("id", json.string(entry.id)),
        #("content", json.string(entry.content)),
        #("embedding", json.array(entry.embedding, of: fn(v) { json.float(v) })),
        #("session_id", json.string(entry.session_id)),
        #("timestamp", json.int(entry.timestamp)),
      ])
    })
  let body =
    json.object([#("entries", json.array(entries_json, of: fn(e) { e }))])
    |> json.to_string
  simplifile.write(store.index_path, body)
  |> result.map_error(fn(_) { "Failed to write vector index" })
}

fn decode_entry_list() -> decode.Decoder(List(EmbeddingEntry)) {
  use entries <- decode.field("entries", decode.list(decode_entry()))
  decode.success(entries)
}

fn decode_entry() -> decode.Decoder(EmbeddingEntry) {
  use id <- decode.field("id", decode.string)
  use content <- decode.field("content", decode.string)
  use embedding <- decode.field("embedding", decode.list(decode.float))
  use session_id <- decode.field("session_id", decode.string)
  use timestamp <- decode.field("timestamp", decode.int)
  decode.success(EmbeddingEntry(
    id: id,
    content: content,
    embedding: embedding,
    session_id: session_id,
    timestamp: timestamp,
  ))
}

fn generate_embedding(
  text: String,
  backend: EmbeddingBackend,
  api_key: String,
) -> Result(List(Float), String) {
  case backend {
    Disabled -> Error("Vector backend disabled")
    HashEmbeddings -> Ok(hash_embedding(text, 128))
    ApiEmbeddings -> {
      case api_key {
        "" -> Ok(hash_embedding(text, 128))
        _ -> semantic_search.generate_embedding(text, api_key)
      }
    }
  }
}

fn hash_embedding(text: String, dims: Int) -> List(Float) {
  let words = string.split(text, " ")
  let chars = string.to_graphemes(text)
  let initial = list.repeat(0.0, dims)
  list.fold(words, initial, fn(acc, word) {
    let h = simple_hash(word, 0)
    let idx = case dims {
      0 -> 0
      d -> int.absolute_value(h) % d
    }
    list.index_map(acc, fn(v, i) {
      case i == idx {
        True -> v +. 1.0
        False -> v
      }
    })
  })
  |> list.append(
    list.fold(chars, list.repeat(0.0, dims), fn(acc, char) {
      let h = simple_hash(char, 1)
      let idx = case dims {
        0 -> 0
        d -> int.absolute_value(h) % d
      }
      list.index_map(acc, fn(v, i) {
        case i == idx {
          True -> v +. 0.5
          False -> v
        }
      })
    }),
  )
  |> list.take(dims)
}

fn simple_hash(s: String, seed: Int) -> Int {
  list.fold(string.to_graphemes(s), seed, fn(acc, char) {
    let code = case char_to_code(char) {
      Some(c) -> c
      None -> 0
    }
    acc * 31 + code
  })
}

@external(erlang, "erlang", "list_to_integer")
fn char_to_code_helper(s: String) -> Int

fn char_to_code(char: String) -> Option(Int) {
  case char {
    "" -> None
    _ -> {
      let bytes = bit_array.byte_size(<<>>)
      let _ = bytes
      Some(char_to_code_helper(char))
    }
  }
}

pub fn add(
  store: VectorStore,
  content: String,
  session_id: String,
  api_key: String,
) -> VectorStore {
  case generate_embedding(content, store.embedding_backend, api_key) {
    Ok(embedding) -> {
      let id = session_id <> "_" <> int.to_string(system_time_seconds())
      let entry = EmbeddingEntry(
        id: id,
        content: content,
        embedding: embedding,
        session_id: session_id,
        timestamp: system_time_seconds(),
      )
      let _ = save_index(VectorStore(..store, entries: [entry, ..store.entries]))
      VectorStore(..store, entries: [entry, ..store.entries])
    }
    Error(_) -> store
  }
}

pub fn search(
  store: VectorStore,
  query: String,
  api_key: String,
  limit limit: Int,
) -> List(SearchResult) {
  case store.embedding_backend {
    Disabled -> []
    _ -> {
      case generate_embedding(query, store.embedding_backend, api_key) {
        Error(_) -> []
        Ok(query_vec) -> {
          store.entries
          |> list.map(fn(entry) {
            let sim = semantic_search.cosine_similarity(query_vec, entry.embedding)
            SearchResult(
              content: entry.content,
              session_id: entry.session_id,
              score: sim,
              source: "vector",
            )
          })
          |> list.filter(fn(r) { r.score >. 0.01 })
          |> list.sort(fn(a, b) { float.compare(b.score, a.score) })
          |> list.take(limit)
        }
      }
    }
  }
}

pub fn rrf_fuse(
  fts_results: List(SearchResult),
  vec_results: List(SearchResult),
  k k: Int,
  limit limit: Int,
) -> List(SearchResult) {
  let fts_ranked = rank_results(fts_results)
  let vec_ranked = rank_results(vec_results)
  let all_ids = list.unique(list.append(
    list.map(fts_ranked, fn(r) { r.1.content }),
    list.map(vec_ranked, fn(r) { r.1.content }),
  ))
  list.map(all_ids, fn(content) {
    let fts_rank = find_rank(fts_ranked, content)
    let vec_rank = find_rank(vec_ranked, content)
    let fts_score = case fts_rank {
      Some(rank) -> 1.0 /. { int.to_float(k) +. int.to_float(rank) }
      None -> 0.0
    }
    let vec_score = case vec_rank {
      Some(rank) -> 1.0 /. { int.to_float(k) +. int.to_float(rank) }
      None -> 0.0
    }
    SearchResult(
      content: content,
      session_id: find_session_id(fts_ranked, vec_ranked, content),
      score: fts_score +. vec_score,
      source: "rrf",
    )
  })
  |> list.sort(fn(a, b) { float.compare(b.score, a.score) })
  |> list.take(limit)
}

fn rank_results(results: List(SearchResult)) -> List(#(Int, SearchResult)) {
  list.index_map(results, fn(r, idx) { #(idx + 1, r) })
}

fn find_rank(
  ranked: List(#(Int, SearchResult)),
  content: String,
) -> Option(Int) {
  case list.find(ranked, fn(pair) { pair.1.content == content }) {
    Ok(pair) -> Some(pair.0)
    Error(_) -> None
  }
}

fn find_session_id(
  fts: List(#(Int, SearchResult)),
  vec: List(#(Int, SearchResult)),
  content: String,
) -> String {
  case find_rank(fts, content) {
    Some(rank) -> {
      case list.first(list.drop(fts, rank - 1)) {
        Ok(pair) -> pair.1.session_id
        Error(_) -> ""
      }
    }
    None -> {
      case find_rank(vec, content) {
        Some(rank) -> {
          case list.first(list.drop(vec, rank - 1)) {
            Ok(pair) -> pair.1.session_id
            Error(_) -> ""
          }
        }
        None -> ""
      }
    }
  }
}

pub fn format_results(results: List(SearchResult)) -> String {
  case results {
    [] -> "No results found."
    _ -> {
      results
      |> list.index_map(fn(r, idx) {
        int.to_string(idx + 1)
        <> ". ["
        <> r.source
        <> " score="
        <> float.to_string(r.score)
        <> "] "
        <> string.slice(r.content, 0, 120)
      })
      |> string.join("\n")
    }
  }
}

pub fn clear(store: VectorStore) -> Result(Nil, String) {
  let empty = VectorStore(..store, entries: [])
  save_index(empty)
}

pub fn entry_count(store: VectorStore) -> Int {
  list.length(store.entries)
}

pub fn memory_stats(store: VectorStore) -> Dict(String, String) {
  dict.from_list([
    #("entries", int.to_string(list.length(store.entries))),
    #("backend", backend_label(store.embedding_backend)),
    #("index_path", store.index_path),
  ])
}

fn backend_label(backend: EmbeddingBackend) -> String {
  case backend {
    ApiEmbeddings -> "api (text-embedding-3-small)"
    HashEmbeddings -> "local hash (128-dim, offline)"
    Disabled -> "disabled"
  }
}

@external(erlang, "math", "sqrt")
pub fn sqrt(x: Float) -> Float
