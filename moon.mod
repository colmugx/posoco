name = "colmugx/posoco"

version = "0.4.1"

import {
  "moonbitlang/async@0.20.0",
}

readme = "README.mbt.md"

repository = "https://github.com/colmugx/posoco"

license = "Apache-2.0"

keywords = [ "llm", "agent", "framework", "ports-and-adapters", "ai-runtime" ]

description = "Zero-dependency LLM Agent framework with hexagonal (ports-and-adapters) architecture. Defines 7 traits + Agent loop."

options(
  source: "src",
  exclude: [ "external", "docs" ],
)
