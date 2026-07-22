///|
pub(all) enum ToolChoice {
  Auto
  NoTool
  Required
  NamedTool(String)
} derive(Eq, Debug)

///|
/// Reasoning effort requested of the model. Provider-agnostic: each ext maps
/// these to its own effort tiers (e.g. DeepSeek collapses to on/off via model
/// choice; OpenAI/Anthropic have explicit tiers). `Maximum` means the provider's
/// absolute top tier (Claude ultra, DeepSeek Max, OpenAI high).
pub(all) enum ReasoningEffort {
  Off
  Minimal
  Low
  Medium
  High
  Maximum
} derive(Eq, Debug)

///|
pub(all) struct ChatOptions {
  temperature : Double?
  max_output_tokens : Int?
  tool_choice : ToolChoice?
  reasoning_effort : ReasoningEffort?
} derive(Eq, Debug)
