defmodule Giulia.MCP.Dispatch.Runtime do
  @moduledoc """
  MCP dispatch handlers for the `runtime_*` tool family.

  Wraps `Giulia.Runtime.{Inspector, Collector, Monitor, Observer,
  IngestStore}` calls. Most handlers accept an optional `node` arg
  (resolved via `Helpers.resolve_node/1`) to target a remote BEAM node.
  """

  import Giulia.MCP.Dispatch.Helpers

  alias Giulia.Core.PathMapper
  alias Giulia.Daemon.Helpers, as: DaemonHelpers
  alias Giulia.Runtime.{Collector, IngestStore, Inspector, Monitor}

  @spec pulse(map()) :: {:ok, term()}
  def pulse(args) do
    {:ok, Inspector.pulse(resolve_node(args["node"]))}
  end

  @spec top_processes(map()) :: {:ok, term()}
  def top_processes(args) do
    node_ref = resolve_node(args["node"])
    metric = atom_arg(args["metric"], :reductions)
    {:ok, Inspector.top_processes(node_ref, metric)}
  end

  @spec hot_spots(map()) :: {:ok, term()}
  def hot_spots(args) do
    node_ref = resolve_node(args["node"])
    path = if args["path"], do: PathMapper.resolve_path(args["path"]), else: nil
    {:ok, Inspector.hot_spots(node_ref, path)}
  end

  @spec trace(map()) :: {:ok, term()} | {:error, String.t()}
  def trace(args) do
    with {:ok, module} <- require_param(args, "module") do
      node_ref = resolve_node(args["node"])
      duration = parse_int(args["duration"], 5000)
      {:ok, Inspector.trace(node_ref, module, duration)}
    end
  end

  @spec history(map()) :: {:ok, term()}
  def history(args) do
    node_ref = resolve_node(args["node"])
    last_n = parse_int(args["last"], 20)
    {:ok, Collector.history(node_ref, last_n)}
  end

  @spec trend(map()) :: {:ok, term()}
  def trend(args) do
    node_ref = resolve_node(args["node"])
    metric = atom_arg(args["metric"], :memory)
    {:ok, Collector.trend(node_ref, metric)}
  end

  @spec alerts(map()) :: {:ok, term()}
  def alerts(args) do
    node_ref = resolve_node(args["node"])
    {:ok, Collector.alerts(node_ref)}
  end

  @spec connect(map()) :: {:ok, term()} | {:error, String.t()}
  def connect(args) do
    with {:ok, node_str} <- require_param(args, "node") do
      # safe_to_node_atom returns `:local` for malformed input
      # (anything not matching `name@host`). Treat it as the sentinel
      # for "rejected by validator" — explicit `"local"` input lands
      # here too, which is the intended behavior since `:local` is
      # the in-process pseudo-node, not a connectable target.
      case DaemonHelpers.safe_to_node_atom(node_str) do
        :local ->
          {:error, "Invalid node name: #{node_str} (expected name@host)"}

        node_atom when is_atom(node_atom) ->
          cookie = args["cookie"]
          {:ok, Inspector.connect(node_atom, cookie)}
      end
    end
  end

  @spec monitor_status(map()) :: {:ok, term()}
  def monitor_status(_args), do: {:ok, Monitor.status()}

  @spec profiles(map()) :: {:ok, term()}
  def profiles(args) do
    limit = parse_int(args["limit"], 20)
    {:ok, Monitor.list_profiles(limit)}
  end

  @spec profile_latest(map()) :: {:ok, term()} | {:error, String.t()}
  def profile_latest(_args) do
    # Monitor.latest_profile/0 returns `{:error, :not_found}`, not
    # `:no_profiles` — the original MCP.Server clause matched the wrong
    # atom and would FunctionClauseError on every empty-profile path.
    case Monitor.latest_profile() do
      {:ok, profile} -> {:ok, profile}
      {:error, :not_found} -> {:error, "No profiles available"}
    end
  end

  @spec profile_by_id(map()) :: {:ok, term()} | {:error, String.t()}
  def profile_by_id(args) do
    with {:ok, id} <- require_param(args, "id") do
      case Monitor.get_profile(id) do
        {:ok, profile} -> {:ok, profile}
        {:error, :not_found} -> {:error, "Profile not found: #{id}"}
      end
    end
  end

  @spec ingest(map()) :: {:ok, term()}
  def ingest(args), do: {:ok, IngestStore.ingest(args)}

  @spec ingest_finalize(map()) :: {:ok, term()}
  def ingest_finalize(args), do: {:ok, IngestStore.finalize(args)}

  @spec observations(map()) :: {:ok, term()}
  def observations(_args), do: {:ok, IngestStore.list_observations()}

  @spec observation_by_session_id(map()) :: {:ok, term()} | {:error, String.t()}
  def observation_by_session_id(args) do
    with {:ok, session_id} <- require_param(args, "session_id") do
      case IngestStore.get_observation(session_id) do
        {:ok, obs} -> {:ok, obs}
        {:error, :not_found} -> {:error, "Observation not found: #{session_id}"}
      end
    end
  end

  defp atom_arg(nil, default), do: default

  defp atom_arg(val, default) when is_binary(val) do
    String.to_existing_atom(val)
  rescue
    ArgumentError -> default
  end

  defp atom_arg(_, default), do: default
end
