///|
/// `CatalogSource` — a host-owned, versioned tool catalog (experimental
/// runtime seam). Advanced hosts whose tool set changes over the Agent's
/// lifetime (dynamic registration, trust/capability gates, remote tool
/// protocols) supply one via `Agent::with_runtime(catalog_source~)`; plain
/// extension authors declare tools through `ToolProvider` and never need
/// this.
///
/// Read protocol — Posoco reads the source only at well-defined points:
/// - once at Agent construction (the initial snapshot), and
/// - at operation admission (turn, resume, wakeup or idle compact) when
///   `revision()` differs from the last read. Follow-ups within the same
///   operation keep the captured catalog and bindings.
///
/// Each revision change triggers exactly one rebuild attempt. When the
/// rebuilt definitions fail catalog validation (name collision, malformed
/// schema), the previous snapshot stays in effect and the failure is
/// surfaced as a `secondary_failure` observer event — the turn is never
/// aborted. To retry, change `revision()` again.
///
/// An in-flight run always keeps the snapshot (and catalog version) it
/// started with; refreshes only affect subsequent runs. Posoco pins the
/// catalog version monotonically — the source's `revision` is an opaque
/// change signal and is never used as the catalog version itself.
///
/// This legacy seam supplies definitions, not fixed implementations. Direct
/// execution remains the host Runtime's responsibility. Bound dynamic groups
/// are merged atomically and cannot be shadowed by a source update.
pub(open) trait CatalogSource {
  /// Opaque change signal. Any change since the last read triggers one
  /// catalog rebuild at the next operation boundary. Values are compared for
  /// inequality only — they do not need to be monotonic.
  fn revision(Self) -> Int32

  /// The current canonical tool definitions. Unlike `ToolProvider`
  /// declarations, these are taken verbatim: each definition's `owner` and
  /// `policy` are respected as-is, so the source controls execution
  /// scheduling (`Sequential`/`Parallel`/`Exclusive`) per tool.
  ///
  /// Core basic tools (the built-in memory surface) are merged ahead of
  /// these definitions in the model-facing catalog; a source definition
  /// colliding with a basic name is shadowed (basic wins).
  fn tools(Self) -> Array[@kernel.ToolDef]
}
