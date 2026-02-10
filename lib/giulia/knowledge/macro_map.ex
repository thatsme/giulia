defmodule Giulia.Knowledge.MacroMap do
  @moduledoc """
  Static knowledge base mapping `use Module` to injected function signatures.

  Replaces the prose-level `@known_macro_implications` in Preflight with
  precise `{name, arity}` tuples. Used by:
  - `Analyzer.behaviour_integrity/3` to eliminate false-positive fractures
  - `Preflight.macro_contract/2` for structured contract output

  Matching: last segment of module name (e.g., `use MyApp.GenServer` won't
  incorrectly match, but the `use GenServer` directive stores `"GenServer"`
  which does match).
  """

  @macro_injections %{
    # GenServer — 9 callbacks
    "GenServer" => [
      {"init", 1},
      {"handle_call", 3},
      {"handle_cast", 2},
      {"handle_info", 2},
      {"handle_continue", 2},
      {"terminate", 2},
      {"code_change", 3},
      {"child_spec", 1},
      {"start_link", 1}
    ],
    # Supervisor — 3 callbacks
    "Supervisor" => [
      {"init", 1},
      {"child_spec", 1},
      {"start_link", 1}
    ],
    # Agent — 3 callbacks
    "Agent" => [
      {"start_link", 1},
      {"child_spec", 1},
      {"start", 1}
    ],
    # Application — 2 callbacks
    "Application" => [
      {"start", 2},
      {"stop", 1}
    ],
    # Plug.Router — 2 injected
    "Plug.Router" => [
      {"init", 1},
      {"call", 2}
    ],
    # Plug.Builder — 2 injected
    "Plug.Builder" => [
      {"init", 1},
      {"call", 2}
    ],
    # Phoenix.Controller — 1 injected
    "Phoenix.Controller" => [
      {"action", 2}
    ],
    # Phoenix.LiveView — 2 lifecycle callbacks
    "Phoenix.LiveView" => [
      {"mount", 3},
      {"render", 1}
    ],
    # ExUnit.Case — 2 injected
    "ExUnit.Case" => [
      {"__ex_unit__", 0},
      {"setup", 1}
    ],
    # GenStateMachine — 4 callbacks
    "GenStateMachine" => [
      {"init", 1},
      {"handle_event", 4},
      {"terminate", 3},
      {"code_change", 4}
    ]
  }

  @doc """
  Returns the list of `{name, arity}` function signatures injected by `use Module`.
  Matches on the last segment of the module name.

  ## Examples

      iex> MacroMap.injected_functions("GenServer")
      [{"init", 1}, {"handle_call", 3}, ...]

      iex> MacroMap.injected_functions("Unknown.Thing")
      []
  """
  @spec injected_functions(String.t()) :: [{String.t(), non_neg_integer()}]
  def injected_functions(module_name) do
    last_segment = module_name |> String.split(".") |> List.last()

    Enum.flat_map(@macro_injections, fn {key, functions} ->
      key_last = key |> String.split(".") |> List.last()
      if key_last == last_segment, do: functions, else: []
    end)
  end

  @doc """
  Returns true if `{function, arity}` is injected by any of the given `use` directives.

  ## Examples

      iex> MacroMap.injected?(["GenServer"], "init", 1)
      true

      iex> MacroMap.injected?(["GenServer"], "my_custom_func", 0)
      false
  """
  @spec injected?([String.t()], String.t(), non_neg_integer()) :: boolean()
  def injected?(use_directives, function, arity) do
    Enum.any?(use_directives, fn directive ->
      directive
      |> injected_functions()
      |> Enum.member?({function, arity})
    end)
  end

  @doc """
  Returns the full macro injection map.
  """
  @spec all() :: %{String.t() => [{String.t(), non_neg_integer()}]}
  def all, do: @macro_injections
end
