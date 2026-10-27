///|
pub struct ToolPublisher {
  priv initial : &@port.ToolProvider
  priv mut contributions : @port.ToolContributions?
}

///|
pub fn ToolPublisher::ToolPublisher(
  initial : &@port.ToolProvider,
) -> ToolPublisher {
  { initial, contributions: None, }
}

///|
pub impl @port.Extension for ToolPublisher with fn extension_id(_) {
  "published"
}

///|
pub impl @port.Extension for ToolPublisher with fn manifest(self) {
  @port.ExtensionManifest(id="published", lifecycle=[self], requires=[
    @port.ToolContribution,
  ])
}

///|
impl @port.Lifecycle for ToolPublisher with fn on_compose(self, view) {
  self.contributions = view.tool_contributions()
}

///|
impl @port.Lifecycle for ToolPublisher with fn on_start(self) {
  self.publish(self.initial)
}

///|
pub async fn ToolPublisher::publish(
  self : ToolPublisher,
  provider : &@port.ToolProvider,
) -> Unit {
  match self.contributions.unwrap().replace(provider~) {
    Ok(_) => ()
    Err(error) => fail(error.to_string())
  }
}

///|
pub fn ToolPublisher::capability(
  self : ToolPublisher,
) -> @port.ToolContributions {
  self.contributions.unwrap()
}

///|
pub extend ToolPublisher with @port.Extension::{manifest, extension_id}
