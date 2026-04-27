defmodule Giulia.Enrichment.Registry do
  @moduledoc """
  Plugin registry for enrichment sources.

  Reads `priv/config/enrichment_sources.json` once per VM, caches the
  resolved module list in `:persistent_term` for free reads. Adding a
  new tool is a JSON edit + daemon restart — no code change here.

  Mirrors the `Giulia.Knowledge.DispatchPatterns` / `ScoringConfig`
  loader pattern so consumers learn one mechanism, not five.
  """

  require Logger

  @config_file "config/enrichment_sources.json"
  @persistent_term_key {__MODULE__, :sources}

  @doc """
  Returns a map of `tool_name => source_module` for every registered
  source. Cached after first call.
  """
  @spec sources() :: %{atom() => module()}
  def sources do
    case :persistent_term.get(@persistent_term_key, :unset) do
      :unset ->
        loaded = load()
        :persistent_term.put(@persistent_term_key, loaded)
        loaded

      cached ->
        cached
    end
  end

  @doc """
  Look up the source module for a tool name. Accepts atom or string;
  returns `{:ok, module}` or `:error`.
  """
  @spec fetch_source(atom() | String.t()) :: {:ok, module()} | :error
  def fetch_source(tool) when is_binary(tool) do
    case safe_to_atom(tool) do
      {:ok, atom} -> fetch_source(atom)
      :error -> :error
    end
  end

  def fetch_source(tool) when is_atom(tool) do
    case Map.fetch(sources(), tool) do
      {:ok, module} -> {:ok, module}
      :error -> :error
    end
  end

  @doc """
  Force-reload the registry from disk. Used by tests and after a
  config edit + daemon restart.
  """
  @spec reload() :: %{atom() => module()}
  def reload do
    loaded = load()
    :persistent_term.put(@persistent_term_key, loaded)
    loaded
  end

  defp load do
    path = Path.join(:code.priv_dir(:giulia) |> to_string(), @config_file)

    with {:ok, content} <- File.read(path),
         {:ok, %{"sources" => entries}} when is_list(entries) <- Jason.decode(content) do
      Enum.reduce(entries, %{}, fn entry, acc ->
        case entry do
          %{"tool" => tool, "module" => module_str}
          when is_binary(tool) and is_binary(module_str) ->
            Map.put(acc, String.to_atom(tool), Module.concat([module_str]))

          _ ->
            acc
        end
      end)
    else
      err ->
        Logger.error(
          "Giulia.Enrichment.Registry: #{@config_file} missing or malformed " <>
            "(got: #{inspect(err)}). No enrichment sources registered."
        )

        %{}
    end
  end

  defp safe_to_atom(string) do
    {:ok, String.to_existing_atom(string)}
  rescue
    ArgumentError -> :error
  end
end
