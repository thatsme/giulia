defmodule Giulia.Enrichment.Registry do
  @moduledoc """
  Plugin registry for enrichment sources.

  Reads `priv/config/enrichment_sources.json` once per VM, caches the
  resolved configuration in `:persistent_term` for free reads. Adding
  a new tool is a JSON edit + daemon restart — no code change here.

  Each source entry carries:
    - `tool`        (string)  — atom-keyed identifier (`credo`, `dialyzer`, ...)
    - `module`      (string)  — implementing module name
    - `severity_map` (object, optional) — tool-specific category/check
      → severity (`info`/`warning`/`error`) overrides
    - `default_severity` (string, optional) — fallback severity when
      `severity_map` doesn't match. Defaults to `info`.

  Source modules call `severity_for/2` to translate a tool-emitted
  category/check string into the canonical severity, putting all
  tunable mappings in one JSON file rather than scattering them
  across `.ex` source per-tool.

  Mirrors the `Giulia.Knowledge.DispatchPatterns` / `ScoringConfig`
  loader pattern so consumers learn one mechanism, not five.
  """

  require Logger

  @config_file "config/enrichment_sources.json"
  @persistent_term_key {__MODULE__, :state}

  @typep state :: %{
           modules: %{atom() => module()},
           configs: %{atom() => map()}
         }

  @doc """
  Returns a map of `tool_name => source_module` for every registered
  source. Cached after first call. Backward-compatible API — only
  the module mapping is exposed here; per-source tunables go through
  `config_for/1` and `severity_for/2`.
  """
  @spec sources() :: %{atom() => module()}
  def sources, do: state().modules

  @doc """
  Returns the per-source config map for `tool` (severity_map,
  default_severity, plus any future tunables). Returns `%{}` when
  the tool is not registered.
  """
  @spec config_for(atom() | String.t()) :: map()
  def config_for(tool) when is_binary(tool) do
    case safe_to_atom(tool) do
      {:ok, atom} -> config_for(atom)
      :error -> %{}
    end
  end

  def config_for(tool) when is_atom(tool) do
    Map.get(state().configs, tool, %{})
  end

  @doc """
  Translate a tool-emitted category/check string into a canonical
  severity atom (`:info | :warning | :error`). Reads the source's
  `severity_map`; falls back to `default_severity`; falls back to
  `:info` if neither is configured.
  """
  @spec severity_for(atom(), String.t() | nil) :: :info | :warning | :error
  def severity_for(tool, category) when is_atom(tool) do
    cfg = config_for(tool)
    severity_map = Map.get(cfg, "severity_map", %{})

    raw =
      case category do
        c when is_binary(c) -> Map.get(severity_map, c)
        _ -> nil
      end

    raw = raw || Map.get(cfg, "default_severity", "info")
    normalize_severity(raw)
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
    case Map.fetch(state().modules, tool) do
      {:ok, module} -> {:ok, module}
      :error -> :error
    end
  end

  @doc """
  Force-reload the registry from disk. Used by tests and after a
  config edit + daemon restart.
  """
  @spec reload() :: state()
  def reload do
    loaded = load()
    :persistent_term.put(@persistent_term_key, loaded)
    loaded
  end

  @spec state() :: state()
  defp state do
    case :persistent_term.get(@persistent_term_key, :unset) do
      :unset ->
        loaded = load()
        :persistent_term.put(@persistent_term_key, loaded)
        loaded

      cached ->
        cached
    end
  end

  defp load do
    path = Path.join(:code.priv_dir(:giulia) |> to_string(), @config_file)

    with {:ok, content} <- File.read(path),
         {:ok, %{"sources" => entries}} when is_list(entries) <- Jason.decode(content) do
      Enum.reduce(entries, %{modules: %{}, configs: %{}}, fn entry, acc ->
        case entry do
          %{"tool" => tool, "module" => module_str}
          when is_binary(tool) and is_binary(module_str) ->
            tool_atom = String.to_atom(tool)
            mod = Module.concat([module_str])

            cfg =
              entry
              |> Map.delete("tool")
              |> Map.delete("module")

            %{
              modules: Map.put(acc.modules, tool_atom, mod),
              configs: Map.put(acc.configs, tool_atom, cfg)
            }

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

        %{modules: %{}, configs: %{}}
    end
  end

  defp normalize_severity("info"), do: :info
  defp normalize_severity("warning"), do: :warning
  defp normalize_severity("error"), do: :error
  defp normalize_severity(:info), do: :info
  defp normalize_severity(:warning), do: :warning
  defp normalize_severity(:error), do: :error
  defp normalize_severity(_), do: :info

  defp safe_to_atom(string) do
    {:ok, String.to_existing_atom(string)}
  rescue
    ArgumentError -> :error
  end
end
