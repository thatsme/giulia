defmodule Giulia.Enrichment.Source do
  @moduledoc """
  Behaviour for external-tool enrichment sources (Credo, Dialyzer, ExUnit
  coverage, ExDoc, Sobelow). Each implementation parses a tool's output
  file into a normalized `finding/0` shape that the rest of the
  enrichment pipeline (Writer, Reader, consumer endpoints) can consume
  uniformly.

  Adding a new tool: implement this behaviour, register the module in
  `priv/config/enrichment_sources.json`. No core code changes.
  """

  @type tool_name :: atom()
  @type granularity :: :module | :function | :line
  @type severity :: :info | :warning | :error

  @typedoc """
  A normalized enrichment finding. The `:scope` field discriminates
  whether the finding attaches to a function vertex (`:function`, must
  also carry `:function` and `:arity`) or a module vertex (`:module`,
  function/arity absent).

  `:resolution_ambiguous` (defaulted to `false` by the writer) signals
  that the parser fell back to module-level attach because the
  function-level resolution surfaced multiple candidates with different
  names. Consumers can use this to weight the finding lower.

  `:column` and `:column_end` are persisted when the source provides
  them (currently Credo) but not consumed today. Free future-proofing
  for IDE-style integrations.
  """
  @type finding :: %{
          required(:scope) => :module | :function,
          required(:module) => String.t(),
          optional(:function) => String.t(),
          optional(:arity) => non_neg_integer(),
          required(:severity) => severity(),
          required(:check) => String.t(),
          required(:message) => String.t(),
          optional(:line) => non_neg_integer(),
          optional(:column) => non_neg_integer(),
          optional(:column_end) => non_neg_integer(),
          optional(:resolution_ambiguous) => boolean()
        }

  @doc "The tool's identifier (`:credo`, `:dialyzer`, ...). Used as the storage key prefix."
  @callback tool_name() :: tool_name()

  @doc "Whether the tool's findings naturally attach to modules, functions, or specific lines."
  @callback target_granularity() :: granularity()

  @doc """
  Parse a tool output file at `payload_path` (and optionally use
  per-project context like function line ranges) into a list of
  normalized findings.

  Returns `{:error, reason}` for unreadable / malformed input. The
  ingest orchestrator turns the error into a parse_error telemetry
  event without crashing the pipeline.
  """
  @callback parse(payload_path :: String.t(), project_path :: String.t()) ::
              {:ok, [finding()]} | {:error, term()}
end
