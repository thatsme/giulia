defmodule Giulia.MCP.Dispatch.Helpers do
  @moduledoc """
  Shared argument-coercion helpers for MCP tool dispatch.

  Each `Giulia.MCP.Dispatch.<Category>` module imports these to validate
  required parameters and coerce string-shaped MCP inputs into the
  Elixir-typed values business-logic functions expect.

  All functions are pure of MCP-protocol concerns — they take a plain
  `args :: map()` (string-keyed JSON), return either the validated/coerced
  value or a tagged error tuple the dispatcher can lift into an MCP error
  response.
  """

  alias Giulia.Core.PathMapper
  alias Giulia.Daemon.Helpers, as: DaemonHelpers

  @doc """
  Pulls `args["path"]` and resolves it via `PathMapper.resolve_path/1`.

  Returns `{:ok, resolved_path}` when the key is present, or
  `{:error, "Missing required parameter: path"}` otherwise. Resolution
  itself does not validate filesystem existence — that's the caller's
  responsibility (the underlying business-logic call usually surfaces a
  meaningful error if the path doesn't resolve to a known project).
  """
  @spec require_path(map()) :: {:ok, String.t()} | {:error, String.t()}
  def require_path(args) do
    case args["path"] do
      nil -> {:error, "Missing required parameter: path"}
      path -> {:ok, PathMapper.resolve_path(path)}
    end
  end

  @doc """
  Pulls a required string parameter by name from `args`.

  Returns `{:ok, value}` or `{:error, "Missing required parameter: <name>"}`.
  """
  @spec require_param(map(), String.t()) :: {:ok, term()} | {:error, String.t()}
  def require_param(args, name) do
    case args[name] do
      nil -> {:error, "Missing required parameter: #{name}"}
      val -> {:ok, val}
    end
  end

  @doc """
  Resolve `args["node"]` to a node atom suitable for `Runtime.Inspector` calls.

  Empty / missing / malformed values resolve to `:local`. Valid `name@host`
  strings round-trip through `safe_to_node_atom/1` (which itself returns
  `:local` for invalid formats) — the dispatcher treats node selection as
  a hint, not a hard contract.
  """
  @spec resolve_node(nil | String.t()) :: atom()
  def resolve_node(nil), do: :local
  def resolve_node(""), do: :local

  def resolve_node(node_str) when is_binary(node_str) do
    DaemonHelpers.safe_to_node_atom(node_str)
  end

  @doc """
  Coerce a string / integer / nil into an integer, falling back to `default`.

  Used for query-string-shaped numeric params (`top_k`, `depth`, `limit`).
  """
  @spec parse_int(term(), integer()) :: integer()
  def parse_int(nil, default), do: default

  def parse_int(val, default) when is_binary(val) do
    case Integer.parse(val) do
      {n, _} -> n
      :error -> default
    end
  end

  def parse_int(val, _default) when is_integer(val), do: val
  def parse_int(_, default), do: default

  @doc """
  Coerce a string / float / nil into a float, falling back to `default`.
  """
  @spec parse_float(term(), float()) :: float()
  def parse_float(nil, default), do: default

  def parse_float(val, default) when is_binary(val) do
    case Float.parse(val) do
      {f, _} -> f
      :error -> default
    end
  end

  def parse_float(val, _default) when is_float(val), do: val
  def parse_float(_, default), do: default

  @doc """
  Parse a `conventions` `suppress` parameter: `"rule1:Mod.A,Mod.B;rule2:Mod.C"`.

  Returns `%{rule_name => [module_string, ...]}`. Empty / malformed
  segments are silently dropped — the suppress flag is ergonomic, not a
  validated input.
  """
  @spec parse_suppress(term()) :: map()
  def parse_suppress(nil), do: %{}
  def parse_suppress(""), do: %{}

  def parse_suppress(raw) when is_binary(raw) do
    raw
    |> String.split(";")
    |> Enum.reduce(%{}, fn entry, acc ->
      case String.split(entry, ":", parts: 2) do
        [rule, modules] ->
          module_list =
            modules
            |> String.split(",")
            |> Enum.map(&String.trim/1)
            |> Enum.reject(&(&1 == ""))

          if module_list != [], do: Map.put(acc, rule, module_list), else: acc

        _ ->
          acc
      end
    end)
  end

  def parse_suppress(_), do: %{}
end
