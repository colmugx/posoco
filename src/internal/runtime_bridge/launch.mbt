///|
priv struct ScopedBoundProvider {
  inner : &@port.ToolProvider
  before_start : () -> @kernel.NotExecutedReason?
}

///|
impl @port.ToolProvider for ScopedBoundProvider with fn list_tools(self) {
  self.inner.list_tools()
}

///|
impl @port.ToolProvider for ScopedBoundProvider with fn execute(self, ctx) {
  // A runtime decorator may await after Started; check the entire captured
  // ancestry immediately before entering the actual provider.
  if (self.before_start)() is Some(reason) {
    return @kernel.ToolOutcome::NotExecuted(
      reason~,
      original_call_id=ctx.call_id,
    )
  }
  self.inner.execute(ctx)
}
