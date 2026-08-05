name = "colmugx/posoco"

version = "0.9.0"

import {
  "moonbitlang/async@0.20.3"
}

readme = "README.mbt.md"

repository = "https://github.com/colmugx/posoco"

license = "Apache-2.0"

keywords = [ "llm", "agent", "framework", "ports-and-adapters", "ai-runtime" ]

description = "LLM Agent framework with hexagonal (ports-and-adapters) architecture. Defines 9 traits + Agent loop. Depends on moonbitlang/async."

source = "src"

options(
  exclude: [ "external", "docs" ],
)
