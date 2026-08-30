///|
fn qc_letters(seed : Int) -> String {
  let n = seed % 8 + 1
  let buf = StringBuilder()
  for i in 0..<n {
    buf.write_char((seed / (i + 3) % 26 + 'a'.to_int()).to_char().unwrap())
  }
  buf.to_string()
}

///|
struct QcSlot {
  name : String
  ptype : @port.ParamType
  raw : String
  expected : Json
  included : Bool
} derive(Debug)

///|
fn qc_slot(idx : Int, kind : Int, val : Int, flag : Int) -> QcSlot {
  // 缩水可能产生负种子；归一化到文档声明的非负值域。
  let norm = fn(i : Int) -> Int { if i < 0 { -i } else { i } }
  let kind = norm(kind)
  let val = norm(val)
  let flag = norm(flag)
  let name = "p\{idx}"
  let included = flag % 2 == 0
  match kind % 4 {
    0 => {
      let s = qc_letters(val)
      { name, ptype: Str, raw: s, expected: Json::string(s), included, }
    }
    1 => {
      let n = val % 10000
      {
        name,
        ptype: Int,
        raw: n.to_string(),
        expected: Json::number(n.to_double()),
        included,
      }
    }
    2 =>
      if val % 2 == 0 {
        {
          name,
          ptype: Bool,
          raw: "true",
          expected: Json::boolean(true),
          included,
        }
      } else {
        {
          name,
          ptype: Bool,
          raw: "false",
          expected: Json::boolean(false),
          included,
        }
      }
    _ => {
      let count = val % 3 + 1
      let parts : Array[Json] = []
      let raws : Array[String] = []
      for j in 0..<count {
        let s = qc_letters(val + j * 977)
        raws.push(s)
        parts.push(Json::string(s))
      }
      {
        name,
        ptype: Strs,
        raw: raws.join(","),
        expected: Json::array(parts),
        included,
      }
    }
  }
}

///|
fn qc_render_case(seeds : Array[(Int, Int, Int)]) -> String {
  let tokens : Array[String] = []
  for i, seed in seeds {
    let (kind, val, flag) = seed
    let slot = qc_slot(i, kind, val, flag)
    if slot.included {
      tokens.push("\{slot.name}=\{slot.raw}")
    }
  }
  "input: '\{tokens.join(" ")}'"
}

///|
test "qc parse_slash_args round trip and default fill" {
  @qc.check(
    (seeds : Array[(Int, Int, Int)]) => {
      let slots = seeds.mapi(fn(i, seed) {
        let (kind, val, flag) = seed
        qc_slot(i, kind, val, flag)
      })
      let params : Array[@port.CommandParam] = []
      let expected : Map[String, Json] = Map::from_array([])
      let tokens : Array[String] = []
      for slot in slots {
        if slot.included {
          params.push(make_param(slot.name, ptype=slot.ptype, required=true))
          tokens.push("\{slot.name}=\{slot.raw}")
        } else {
          params.push(
            make_param(
              slot.name,
              ptype=slot.ptype,
              required=false,
              default=Some(slot.expected),
            ),
          )
        }
        expected[slot.name] = slot.expected
      }
      let result = parse_slash_args(tokens.join(" "), params)
      match result {
        Ok(Object(map)) => {
          if map.length() != expected.length() {
            return false
          }
          for k, v in expected {
            if map.get(k) != Some(v) {
              return false
            }
          }
          true
        }
        _ => false
      }
    },
    observe=seeds => [@qc.collect(seeds.length())],
    counterexample_context=qc_render_case,
  )
}
