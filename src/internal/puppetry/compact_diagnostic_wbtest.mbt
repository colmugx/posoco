///|
/// White-box tests for the compact failure cause relay. Core does not parse
/// the `ModelFailure` reason: it forwards the adapter's opaque safe label —
/// bounded at the 352-character relay budget, newlines flattened — next to
/// the structural `ModelFailure` category, and the whole cause stays under
/// the user-approved 512-character outer error display. These tests pin the
/// generic contract: arbitrary failure formats (Unicode, quoting, `k=v`
/// lookalikes) are never interpreted into fields, labels stay bounded,
/// cancellation stays a distinct outcome, and non-compact phases keep the
/// old 64-character rendering.

///|
/// A label at the adapter's aggregate bound is relayed intact: the kernel's
/// 64-character display truncation does not apply on the compact cause path.

///|
/// Content beyond the relay budget is capped: the far tail cannot resurface
/// and the truncation is marked.
