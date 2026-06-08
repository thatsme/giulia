defmodule Giulia.Search.Facade do
  @moduledoc """
  Per-domain facade for search endpoints — the coerce + call layer for the
  search domain, mirroring `Giulia.Knowledge.Facade`. Reuses the shared
  `Giulia.Daemon.Edge` for resolution + readiness (no cross-domain coupling).

  Returns PLAIN DATA; each protocol renders it. The semantic result is shaped
  ONCE here into the canonical agent-facing form (reshaped modules/functions
  with file/line/score) so REST and MCP converge — previously REST reshaped and
  MCP emitted raw structs with a different `count`.
  """

  alias Giulia.Daemon.Helpers
  alias Giulia.Intelligence.SemanticIndex

  @doc """
  Semantic concept search. Owns the `top_k` default (5), the `concept`/`q` alias
  resolution, and the canonical result shape:

      %{concept, modules: [%{module, score, moduledoc}],
        functions: [%{module, function, arity, score, file, line}],
        count: <modules + functions>}

  `count` is the TOTAL (modules + functions) — the prior REST `count` was
  functions-only, a latent bug. `concept` is required and NOT nil-safe
  (`SemanticIndex.search` embeds it), so absence returns `{:error,
  :missing_concept}` for the protocol to render.
  """
  @spec semantic(String.t(), map()) ::
          {:ok, map()} | {:error, :missing_concept} | {:error, String.t()}
  def semantic(path, params) do
    case params["concept"] || params["q"] do
      blank when blank in [nil, ""] ->
        {:error, :missing_concept}

      concept ->
        top_k = Helpers.parse_int_param(params["top_k"], 5)

        case SemanticIndex.search(path, concept, top_k) do
          {:ok, %{modules: modules, functions: functions}} ->
            mod_json = Enum.map(modules, &format_module/1)
            func_json = Enum.map(functions, &format_function/1)

            {:ok,
             %{
               concept: concept,
               modules: mod_json,
               functions: func_json,
               count: length(mod_json) + length(func_json)
             }}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  defp format_module(m) do
    %{module: m.id, score: m.score, moduledoc: m.metadata[:moduledoc] || ""}
  end

  defp format_function(f) do
    %{
      module: f.metadata.module,
      function: f.metadata.function,
      arity: f.metadata.arity,
      score: f.score,
      file: f.metadata.file,
      line: f.metadata.line
    }
  end
end
