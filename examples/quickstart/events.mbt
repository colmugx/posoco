///|
/// A closed payload ADT inside the shared, open Event type.
/// A reusable protocol would declare these in its own public package.
enum QuickstartProgress {
  Started
}

///|
extenum @posoco.Event += {
  QuickstartChanged(QuickstartProgress)
}

///|
pub impl @posoco.Lifecycle for QuickstartExtension with fn on_compose(
  self,
  view : @posoco.CompositionView,
) -> Unit raise @posoco.CompositionError {
  guard view.events() is Some(events) else {
    raise @posoco.CompositionError::ExtensionComposeFailed(
      manifest_id="quickstart",
      detail="missing declared Events capability",
    )
  }
  self.events.val = Some(events)
}

///|
pub impl @posoco.Lifecycle for QuickstartExtension with fn on_start(self) -> Unit {
  guard self.events.val is Some(events) else {
    abort("quickstart started without its composed Events capability")
  }
  // The Agent binds the source namespace to the manifest id; publishers cannot
  // supply a source string or publish into Posoco's reserved namespace.
  guard events.publish(QuickstartChanged(Started)) is Ok(_) else {
    abort("quickstart could not publish its startup event")
  }
}
