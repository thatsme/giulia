defmodule Giulia.Config.DispatchInvariants do
  @moduledoc """
  Dispatch-time invariants consulted on every analysis: project root
  markers, implicit (framework-dispatched) functions, known external
  behaviour callback signatures, and Phoenix router verbs.

  Loaded once at first call from `priv/config/dispatch_invariants.json`
  and cached in `:persistent_term`. Reads are free; writes only happen
  on the first call after boot.

  Editing the JSON and restarting the daemon picks up new values — no
  recompile, no per-project opt-in. Companion of `ScoringConfig`,
  `DispatchPatterns`, `ScanConfig` — same persistence pattern, same
  loader shape.
  """

  @persistent_term_key {__MODULE__, :config}

  @spec current() :: map()
  def current do
    case :persistent_term.get(@persistent_term_key, :unset) do
      :unset ->
        cfg = load()
        :persistent_term.put(@persistent_term_key, cfg)
        cfg

      cfg ->
        cfg
    end
  end

  @spec reload() :: map()
  def reload do
    cfg = load()
    :persistent_term.put(@persistent_term_key, cfg)
    cfg
  end

  @spec project_markers() :: [String.t()]
  def project_markers, do: current().project_markers

  @spec implicit_functions() :: MapSet.t({String.t(), arity()})
  def implicit_functions, do: current().implicit_functions

  @spec known_behaviours() :: [String.t()]
  def known_behaviours, do: Map.keys(current().known_behaviour_callbacks)

  @spec known_behaviour?(String.t()) :: boolean()
  def known_behaviour?(name), do: Map.has_key?(current().known_behaviour_callbacks, name)

  @spec callbacks_for(String.t()) :: [{atom(), arity()}]
  def callbacks_for(name), do: Map.get(current().known_behaviour_callbacks, name, [])

  @spec router_verbs() :: [atom()]
  def router_verbs, do: current().router_verbs

  @spec router_verb?(atom()) :: boolean()
  def router_verb?(verb), do: verb in current().router_verbs

  defp load do
    path = Path.join(:code.priv_dir(:giulia), "config/dispatch_invariants.json")

    case File.read(path) do
      {:ok, body} ->
        raw = Jason.decode!(body)
        decode(raw)

      {:error, reason} ->
        raise "DispatchInvariants: cannot read #{path}: #{inspect(reason)}"
    end
  end

  defp decode(raw) do
    %{
      project_markers: fetch_strings!(raw, "project_markers"),
      implicit_functions:
        raw
        |> Map.fetch!("implicit_functions")
        |> Enum.map(&decode_name_arity/1)
        |> MapSet.new(),
      known_behaviour_callbacks:
        raw
        |> Map.fetch!("known_behaviour_callbacks")
        |> Map.new(fn {behaviour, callbacks} ->
          {behaviour, Enum.map(callbacks, &decode_callback/1)}
        end),
      router_verbs:
        raw
        |> Map.fetch!("router_verbs")
        |> Enum.map(&String.to_atom/1)
    }
  end

  defp fetch_strings!(raw, key) do
    list = Map.fetch!(raw, key)
    unless Enum.all?(list, &is_binary/1) do
      raise "DispatchInvariants: #{key} must be a list of strings, got #{inspect(list)}"
    end
    list
  end

  defp decode_name_arity([name, arity]) when is_binary(name) and is_integer(arity), do: {name, arity}
  defp decode_name_arity(other),
    do: raise("DispatchInvariants: implicit_functions entry must be [name, arity], got #{inspect(other)}")

  defp decode_callback([name, arity]) when is_binary(name) and is_integer(arity),
    do: {String.to_atom(name), arity}

  defp decode_callback(other),
    do: raise("DispatchInvariants: callback entry must be [name, arity], got #{inspect(other)}")
end
