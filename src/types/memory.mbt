///|
pub(all) struct MemoryEntry {
  id : String
  content : String
  metadata : Map[String, Json]
  score : Double?
} derive(Eq, Debug)

///|
pub(all) struct MemoryQuery {
  query : String
  top_k : Int
  threshold : Double?
  filter : Map[String, Json]
} derive(Eq, Debug)
