///|
/// Semantic command type. Determines how a panel renders the control
/// (button / toggle / dropdown / input / multi-step form) and how a slash
/// parser expects arguments.
pub(all) enum CommandType {
  Action
  Toggle
  Select
  Input
  MultiStep
} derive(Eq, Debug)

///|
/// Value type of a command parameter. Human-friendly (unlike JSON Schema which
/// targets LLMs). Panel/slash consumers render and parse directly from this.
pub(all) enum ParamType {
  Str
  Int
  Bool
  Strs
} derive(Eq, Debug)

///|
/// A single command parameter. Explicit and human-facing, in contrast to
/// ToolDef.input_schema (which is JSON Schema for LLM consumption).
pub(all) struct CommandParam {
  name : String
  label : String
  description : String
  ptype : ParamType
  required : Bool
  default : Json?
  choices : Array[String]?
  positional : Bool
} derive(Eq, Debug)

///|
/// Command declaration. `params` is the source of truth for argument rendering
/// (panel form) and parsing (slash). Redundant fields (aliases/shortcut/icon/
/// visible/metadata) are deliberate "escape hatches" for ext authors to use
/// without changing the trait — meta does not define their semantics.
pub(all) struct CommandDef {
  id : String
  label : String
  description : String
  category : String
  ctype : CommandType
  params : Array[CommandParam]
  aliases : Array[String]
  shortcut : String?
  icon : String?
  visible : Bool
  metadata : Json?
} derive(Eq, Debug)

///|
/// Hint to a panel consumer about what UI action to take after invoke.
/// Slash consumers ignore this. Fixed enum + None fallback; ext long-tail
/// needs go through CommandDef.metadata.
pub(all) enum UiHint {
  RefreshModelList
  RefreshSettings
  ClosePanel
  Toast
  None
} derive(Eq, Debug)

///|
/// Outcome of invoking a command. `feedback` is for slash (print directly);
/// `structured` + `ui_hint` are for panel (deep render + UI action).
/// `NeedsInput` supports multi-step commands.
pub(all) enum CommandOutcome {
  Success(feedback~ : String, structured~ : Json?, ui_hint~ : UiHint?)
  Failure(reason~ : String)
  NeedsInput(prompt~ : String)
} derive(Eq, Debug)

///|
/// User-initiated, enumerable, side-effecting commands. Distinct from
/// ToolProvider (LLM-initiated, results re-enter session). Both panel TUIs
/// and slash command lines consume this without knowing command semantics.
/// `pub(open)` so any ext can declare commands.
pub(open) trait CommandPort {
  fn commands(Self) -> Array[CommandDef]
  async fn invoke(Self, id : String, args : Json) -> CommandOutcome raise CommandError
}
