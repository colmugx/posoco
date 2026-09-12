name = "colmugx/posoco"

version = "0.15.0"

import {
  "Tigls/mb-getrandom@0.1.0",
  "moonbitlang/async@0.21.2",
}

readme = "README.mbt.md"

repository = "https://github.com/colmugx/posoco"

license = "Apache-2.0"

keywords = [ "llm", "agent", "framework", "ports-and-adapters", "ai-runtime" ]

description = "LLM Agent framework with hexagonal (ports-and-adapters) architecture. Defines 9 traits + Agent loop. Depends on moonbitlang/async."

source = "src"

// 暂时引入

preferred_target = "native"
