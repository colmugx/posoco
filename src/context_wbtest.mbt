///|
test "render_context: full attributes match cetas-context output" {
  inspect(
    render_context(
      namespace="cetas",
      kind="project_instructions",
      trust=false,
      source="/repo/AGENTS.md",
      content="Build with: moon test",
    ),
    content="<cetas-context type=\"project_instructions\" trust=\"false\" source=\"/repo/AGENTS.md\">\nBuild with: moon test\n</cetas-context>",
  )
}

///|
test "render_context: default namespace and omitted source" {
  inspect(
    render_context(kind="t", trust=true, content="c"),
    content="<posoco-context type=\"t\" trust=\"true\">\nc\n</posoco-context>",
  )
}

///|
test "render_context: escapes source and content" {
  let rendered = render_context(
    namespace="e",
    kind="t",
    trust=false,
    source="/p?a=<x>",
    content="<tag> & \"q\" 'a'",
  )
  assert_true(rendered.contains("source=\"/p?a=&lt;x&gt;\""))
  assert_true(
    rendered.contains("&lt;tag&gt; &amp; &quot;q&quot; &apos;a&apos;"),
  )
}
