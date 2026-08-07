defmodule Giulia.Knowledge.Otp do
  @moduledoc """
  OTP deep-analysis checks — process architecture, not module structure.

  Credo checks syntax-level style and Dialyzer checks types; neither looks at
  how processes are started or how they talk to each other. These checks target
  bug classes that appear in production and not in tests, because they are
  load- and interleaving-dependent.

  Phase 2 ships the two pure-AST checks:

    * `blocking_init/2` — blocking calls inside `init/1`, which run inside the
      supervisor's start sequence
    * `missing_catch_all_handle_info/1` — a GenServer that defines `handle_info/2`
      clauses but no catch-all, having thereby overridden the injected default

  Findings mirror the `Knowledge.Conventions` shape (`rule`, `message`,
  `category`, `severity`, `file`, `line`, `module`) so report tooling and the
  MCP layer inherit it for free.

  All thresholds and MFA lists come from `Giulia.Config.OtpChecks`
  (`priv/config/otp_checks.json`) — nothing about which calls count as blocking
  is compiled in.
  """

  alias Giulia.Config.OtpChecks
  alias Giulia.Knowledge.Supervision
  alias Giulia.Runtime.Collector

  @behaviour_aliases ["GenServer", "Supervisor"]

  @type finding :: %{
          rule: String.t(),
          message: String.t(),
          category: String.t(),
          severity: String.t(),
          file: String.t(),
          line: non_neg_integer(),
          module: String.t()
        }

  # ============================================================================
  # Entry point
  # ============================================================================

  @doc """
  Run every OTP check over a project, in the conventions response shape.

  `opts` accepts `:suppress` (a `%{rule => [module]}` map, as parsed by
  `Daemon.Helpers.parse_suppress/1`) and `:check` to filter to a single rule.
  """
  @spec otp_risks(String.t(), keyword()) :: {:ok, map()}
  def otp_risks(project_path, opts \\ []) do
    all_asts = Giulia.Context.Store.all_asts(project_path)
    suppress = Keyword.get(opts, :suppress, %{})
    check_filter = Keyword.get(opts, :check)

    modules = parse_modules(all_asts)

    supervisors = Supervision.extract(all_asts)

    findings =
      blocking_init(modules, opts) ++
        missing_catch_all_handle_info(modules) ++
        cross_process_call_cycle(modules) ++
        sync_call_chain_depth(modules) ++
        singleton_bottleneck(modules) ++
        infinity_call_timeout(modules) ++
        one_for_all_amplification(supervisors, modules) ++
        unlinked_start(modules)

    findings =
      findings
      |> filter_by_check(check_filter)
      |> apply_suppressions(suppress)
      |> Enum.sort_by(&{&1.file, &1.line})

    by_severity = Enum.frequencies_by(findings, & &1.severity)

    result = %{
      total_findings: length(findings),
      by_severity: %{
        error: Map.get(by_severity, "error", 0),
        warning: Map.get(by_severity, "warning", 0),
        info: Map.get(by_severity, "info", 0)
      },
      by_check: findings |> Enum.group_by(& &1.rule) |> sort_groups(),
      checks_run: checks_run()
    }

    result = if check_filter, do: Map.put(result, :check_filter, check_filter), else: result
    result = if suppress != %{}, do: Map.put(result, :suppressions_applied, suppress), else: result

    {:ok, result}
  end

  @doc """
  Rules this module currently implements. Phase 3 extends the list.
  """
  @spec checks_run() :: [String.t()]
  def checks_run do
    [
      "blocking_init",
      "missing_catch_all_handle_info",
      "cross_process_call_cycle",
      "sync_call_chain_depth",
      "singleton_bottleneck",
      "infinity_call_timeout",
      "one_for_all_amplification",
      "unlinked_start"
    ]
  end

  # ============================================================================
  # blocking_init
  # ============================================================================

  @doc """
  Blocking calls inside `init/1`, plus the intra-module private-helper closure.

  `init/1` runs inside the supervisor's start sequence: a blocking call
  serialises boot, and a dependency that is down turns into a restart-intensity
  cascade that takes the tree with it. The idiomatic fix is to return
  `{:ok, state, {:continue, :load}}` and do the work in `handle_continue/2`.

  Severity is tiered by `otp_checks.json`: network, DB and cross-process calls
  are errors; `File.*` is a warning, because reading config at boot is
  legitimate and the file's size is unknowable statically.

  A module that already defines `handle_continue/2` gets that noted in the
  finding — the author knows the idiom, so a remaining blocking call is more
  likely deliberate.
  """
  @spec blocking_init([map()], keyword()) :: [finding()]
  def blocking_init(modules, _opts \\ []) do
    modules
    |> Enum.filter(&process_module?/1)
    |> Enum.flat_map(&blocking_calls_in_init/1)
  end

  defp blocking_calls_in_init(module) do
    case Map.fetch(module.functions, {"init", 1}) do
      :error ->
        []

      {:ok, clauses} ->
        reachable = reachable_bodies(module, clauses)

        reachable
        |> Enum.flat_map(&qualified_calls/1)
        |> Enum.flat_map(fn {mfa, line} ->
          case OtpChecks.blocking_severity(mfa) do
            nil -> []
            severity -> [blocking_finding(module, mfa, line, severity)]
          end
        end)
        |> Enum.uniq_by(& &1.message)
    end
  end

  # init/1's own bodies plus the transitive closure of same-module private
  # helpers it calls. A blocking call one hop away from init/1 blocks boot
  # exactly as much as one written inline.
  defp reachable_bodies(module, init_clauses) do
    do_reachable(module, Enum.map(init_clauses, & &1.body), MapSet.new([{"init", 1}]))
  end

  defp do_reachable(module, bodies, visited) do
    called =
      bodies
      |> Enum.flat_map(&unqualified_calls/1)
      |> Enum.reject(&MapSet.member?(visited, &1))
      |> Enum.filter(&Map.has_key?(module.functions, &1))
      |> Enum.uniq()

    case called do
      [] ->
        bodies

      _ ->
        visited = Enum.reduce(called, visited, &MapSet.put(&2, &1))

        next_bodies =
          Enum.flat_map(called, fn key ->
            module.functions |> Map.fetch!(key) |> Enum.map(& &1.body)
          end)

        bodies ++ do_reachable(module, next_bodies, visited)
    end
  end

  defp blocking_finding(module, mfa, line, severity) do
    continue_note =
      if Map.has_key?(module.functions, {"handle_continue", 2}) do
        " (module defines handle_continue/2 — may be deliberate)"
      else
        " — consider {:ok, state, {:continue, :load}} and do this in handle_continue/2"
      end

    %{
      rule: "blocking_init",
      message: "#{mfa} called from init/1 blocks the supervisor start sequence" <> continue_note,
      category: "otp_deep",
      severity: Atom.to_string(severity),
      file: module.file,
      line: line,
      module: module.name
    }
  end

  # ============================================================================
  # missing_catch_all_handle_info
  # ============================================================================

  @doc """
  A GenServer defining `handle_info/2` clauses with no catch-all among them.

  `use GenServer` injects a default `handle_info/2` that logs unexpected
  messages — but defining *any* clause overrides the injected default
  completely. From that moment a late `Task` reply, a `:DOWN` message or port
  noise crashes the server. This is the classic once-a-month-in-production,
  never-in-tests bug.

  Fires only when clauses exist and none is an unguarded catch-all. A module
  defining no `handle_info/2` at all keeps the injected default and is clean —
  flagging it would be a false positive on the majority of GenServers.
  """
  @spec missing_catch_all_handle_info([map()]) :: [finding()]
  def missing_catch_all_handle_info(modules) do
    modules
    |> Enum.filter(&process_module?/1)
    |> Enum.flat_map(fn module ->
      case Map.fetch(module.functions, {"handle_info", 2}) do
        :error ->
          []

        {:ok, clauses} ->
          if Enum.any?(clauses, &catch_all_clause?/1) do
            []
          else
            [
              %{
                rule: "missing_catch_all_handle_info",
                message:
                  "#{module.name} defines #{length(clauses)} handle_info/2 clause(s) but no " <>
                    "catch-all — defining any clause overrides the default `use GenServer` " <>
                    "injects, so an unmatched message now crashes the server",
                category: "otp_deep",
                severity: OtpChecks.missing_catch_all_severity(),
                file: module.file,
                line: clauses |> Enum.map(& &1.line) |> Enum.min(),
                module: module.name
              }
            ]
          end
      end
    end)
  end

  # A catch-all matches any message: first argument is a bare variable (or `_`)
  # and the clause carries no guard. A guarded clause is not a catch-all — the
  # guard is exactly what makes it selective.
  defp catch_all_clause?(%{guarded: true}), do: false

  defp catch_all_clause?(%{args: [{name, _meta, ctx} | _rest]})
       when is_atom(name) and is_atom(ctx),
       do: true

  defp catch_all_clause?(_clause), do: false

  # ============================================================================
  # Synchronous inter-process subgraph (Phase 3 foundation)
  # ============================================================================

  @callback_entry_points [{"handle_call", 3}, {"handle_cast", 2}, {"handle_continue", 2}]
  @default_call_timeout_ms 5_000
  @max_chain_hops 8

  @doc """
  Edges of the synchronous inter-process call graph.

  An edge exists when module A, from inside a `handle_call/3`, `handle_cast/2`
  or `handle_continue/2` body (or a same-module private helper reachable from
  one), performs a `GenServer.call` targeting another GenServer module.

  Only genuine synchronous calls are included. `Topology.cycles/1` carries a
  scar worth heeding here: including `:references` edges once collapsed this
  codebase into a single fake SCC. A subgraph built for cycle detection must
  contain nothing but the relation it claims to model.
  """
  @spec sync_call_edges([map()]) :: [map()]
  def sync_call_edges(modules) do
    implementers = modules |> Enum.filter(&genserver?/1) |> Map.new(&{&1.name, &1})

    # Sync API surface per implementer: public functions wrapping
    # `GenServer.call(__MODULE__, …)`. Calling one of those from inside a
    # callback is a cross-process synchronous call, even though no
    # `GenServer.call` appears at the call site.
    api_surface =
      implementers
      |> Enum.flat_map(fn {name, module} ->
        names = sync_api_names(module)
        if MapSet.size(names) > 0, do: [{name, names}], else: []
      end)
      |> Map.new()

    implementers
    |> Map.values()
    |> Enum.flat_map(fn module ->
      bodies = callback_reachable_bodies(module)

      direct =
        bodies
        |> Enum.flat_map(&genserver_call_sites(&1, module))
        |> Enum.filter(&Map.has_key?(implementers, &1.to))

      via_api = Enum.flat_map(bodies, &api_call_sites(&1, module, api_surface))

      Enum.reject(direct ++ via_api, &(&1.to == module.name))
    end)
    |> Enum.uniq_by(&{&1.from, &1.to})
  end

  # Calls from a callback body to another GenServer's synchronous API wrapper.
  #
  # Without this the subgraph is empty on essentially all real Elixir. Measured
  # across Giulia, Plug, Bandit and Plausible: 72 `GenServer.call` sites, and
  # ZERO of them inside a callback — because the idiom is to wrap the call in a
  # client function, so a callback contains `OtherServer.fetch()`, not
  # `GenServer.call(OtherServer, …)`.
  #
  # Giulia's own `Persistence.Writer` does exactly this: six callback sites
  # calling `Persistence.Store.get_db/1`, which wraps a `GenServer.call`. Real
  # cross-process synchronous calls, invisible to the direct-call-site scan.
  #
  # This is the same false negative that `singleton_bottleneck` had before
  # Phase 4 — the client wrapper hides the process boundary — and it is why the
  # cycle detector reported an empty graph rather than a clean one.
  defp api_call_sites(body, module, api_surface) do
    body
    |> qualified_calls()
    |> Enum.flat_map(fn {mfa, line} ->
      case String.split(mfa, ".") do
        [_single] ->
          []

        parts ->
          fun = List.last(parts)
          target = parts |> Enum.drop(-1) |> Enum.join(".")
          api = Map.get(api_surface, target)

          if api && MapSet.member?(api, fun) do
            [
              %{
                from: module.name,
                to: target,
                line: line,
                # The wrapper owns the timeout; it is not visible at this call
                # site, so the OTP default is the honest assumption.
                timeout: @default_call_timeout_ms
              }
            ]
          else
            []
          end
      end
    end)
  end

  defp callback_reachable_bodies(module) do
    entry_clauses =
      @callback_entry_points
      |> Enum.flat_map(fn key -> Map.get(module.functions, key, []) end)

    case entry_clauses do
      [] -> []
      clauses -> do_reachable(module, Enum.map(clauses, & &1.body), MapSet.new(@callback_entry_points))
    end
  end

  # `GenServer.call(Target, msg)` / `(Target, msg, timeout)` and multi_call.
  # A target that is not a literal module — a pid, a via-tuple, a variable —
  # is skipped: static analysis cannot name the process behind it, and guessing
  # would fabricate edges into the cycle detector.
  defp genserver_call_sites(body, module) do
    {_ast, acc} =
      Macro.prewalk(body, [], fn
        {{:., _, [{:__aliases__, _, [:GenServer]}, fun]}, meta, [target | rest]} = node, acc
        when fun in [:call, :multi_call] ->
          case render_alias(target) do
            nil ->
              {node, acc}

            to ->
              edge = %{
                from: module.name,
                to: to,
                line: meta[:line] || 0,
                timeout: call_timeout(rest)
              }

              {node, [edge | acc]}
          end

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(acc)
  end

  defp call_timeout([_msg, timeout | _]) when is_integer(timeout), do: timeout
  defp call_timeout(_args), do: @default_call_timeout_ms

  # ============================================================================
  # cross_process_call_cycle
  # ============================================================================

  @doc """
  Cycles in the synchronous inter-process call graph — guaranteed deadlocks.

  A blocks waiting on B while B blocks waiting on A; both die by timeout five
  seconds later with stack traces that point nowhere near the cause. It only
  manifests under a specific interleaving, so tests rarely catch it.

  Confidence is `high` when every module in the cycle is a `name: __MODULE__`
  singleton — module identity is then process identity, so the cycle is real.
  Otherwise `medium`: multiple instances may make it harmless. Only `high`
  carries error severity.
  """
  @spec cross_process_call_cycle([map()]) :: [finding()]
  def cross_process_call_cycle(modules) do
    by_name = Map.new(modules, &{&1.name, &1})
    edges = sync_call_edges(modules)

    graph =
      Enum.reduce(edges, Graph.new(type: :directed), fn edge, g ->
        Graph.add_edge(g, edge.from, edge.to)
      end)

    graph
    |> Graph.strong_components()
    |> Enum.filter(&(length(&1) > 1))
    |> Enum.map(&Enum.sort/1)
    |> Enum.map(fn component ->
      all_singletons? = Enum.all?(component, &(by_name |> Map.get(&1, %{}) |> Map.get(:singleton)))
      confidence = if all_singletons?, do: "high", else: "medium"
      anchor = by_name |> Map.fetch!(List.first(component))

      %{
        rule: "cross_process_call_cycle",
        message:
          "synchronous GenServer.call cycle across #{Enum.join(component, " -> ")} -> " <>
            "#{List.first(component)} — each blocks on the next, so the cycle deadlocks " <>
            "until every hop times out (confidence: #{confidence}#{singleton_note(all_singletons?)})",
        category: "otp_deep",
        severity: if(all_singletons?, do: "error", else: "warning"),
        confidence: confidence,
        cycle: component,
        file: anchor.file,
        line: anchor.line,
        module: List.first(component)
      }
    end)
  end

  defp singleton_note(true), do: " — every module is a name: __MODULE__ singleton"
  defp singleton_note(false), do: " — not all endpoints are singletons"

  # ============================================================================
  # sync_call_chain_depth
  # ============================================================================

  @doc """
  Acyclic synchronous chains deeper than the configured threshold.

  Every hop carries its own timeout, so a three-hop chain is a 15-second
  worst-case latency budget nobody approved — and the failure surfaces at the
  OUTERMOST caller, far from the slow hop. The finding carries the full chain
  and the summed budget so the number is arguable rather than asserted.
  """
  @spec sync_call_chain_depth([map()]) :: [finding()]
  def sync_call_chain_depth(modules) do
    by_name = Map.new(modules, &{&1.name, &1})
    edges = sync_call_edges(modules)
    adjacency = Enum.group_by(edges, & &1.from)
    max_depth = OtpChecks.sync_chain_max_depth()

    adjacency
    |> Map.keys()
    |> Enum.flat_map(&longest_chains(&1, adjacency, [], []))
    |> Enum.filter(&(length(&1) > max_depth))
    |> dedupe_subchains()
    |> Enum.map(fn chain ->
      budget = chain |> Enum.map(& &1.timeout) |> Enum.sum()
      path = [List.first(chain).from | Enum.map(chain, & &1.to)]
      anchor = Map.fetch!(by_name, List.first(chain).from)

      %{
        rule: "sync_call_chain_depth",
        message:
          "synchronous call chain #{length(chain)} hops deep: #{Enum.join(path, " -> ")} — " <>
            "worst-case latency budget #{budget}ms, and a timeout surfaces at " <>
            "#{List.first(path)}, not at the slow hop",
        category: "otp_deep",
        severity: "warning",
        chain: path,
        timeout_budget_ms: budget,
        file: anchor.file,
        line: anchor.line,
        module: List.first(path)
      }
    end)
  end

  # Enumerate simple paths (a node never repeats, so cycles terminate the walk
  # and are left to cross_process_call_cycle to report).
  defp longest_chains(node, adjacency, visited, acc_edges) do
    if node in visited or length(acc_edges) >= @max_chain_hops do
      [acc_edges]
    else
      visited = [node | visited]

      case Map.get(adjacency, node, []) do
        [] ->
          [acc_edges]

        next_edges ->
          Enum.flat_map(next_edges, fn edge ->
            longest_chains(edge.to, adjacency, visited, acc_edges ++ [edge])
          end)
      end
    end
  end

  # A 4-hop chain contains a 3-hop chain; reporting both is noise. Keep only
  # chains that are not a prefix of a longer reported one.
  defp dedupe_subchains(chains) do
    sorted = Enum.sort_by(chains, &(-length(&1)))

    Enum.reduce(sorted, [], fn chain, kept ->
      if Enum.any?(kept, &List.starts_with?(&1, chain)), do: kept, else: [chain | kept]
    end)
  end

  # ============================================================================
  # singleton_bottleneck (static half)
  # ============================================================================

  @doc """
  Singleton GenServers receiving synchronous calls from many distinct modules.

  A singleton serialises every caller, so high static fan-in is a *suspicion* of
  a contention point. `runtime` promotes it to a confirmed finding: pass a
  `%{registered_name => %{max_queue_len:, window:}}` map, or `nil` to read the
  Collector ring buffer, or `:unavailable` to force the static-only path.

  ## Fan-in is measured at the API, not at the `GenServer.call`

  The obvious implementation — count `GenServer.call(Target, …)` sites — is
  wrong for idiomatic Elixir, and shipped that way in the first Phase 3 commit.
  The universal pattern wraps the call in a public function:

      def rebuild(path), do: GenServer.call(__MODULE__, {:rebuild, path})

  so the target argument is *always* `__MODULE__` and the real callers are the
  modules invoking `Store.rebuild/1`, one level up. Measured at the call site,
  fan-in is structurally always zero and the check could never fire on
  well-written code — a false negative that a self-scan reporting 0 looks
  identical to a clean codebase.

  Fan-in is therefore: distinct modules calling any public function of the
  singleton whose body performs a `GenServer.call(__MODULE__, …)`. That set is
  the module's synchronous API surface; calls to its other functions do not
  queue on the process and are correctly ignored.
  """
  @spec singleton_bottleneck([map()], map() | nil | :unavailable) :: [finding()]
  def singleton_bottleneck(modules, runtime \\ nil) do
    runtime = if is_nil(runtime), do: collector_queue_data(), else: runtime
    thresholds = OtpChecks.singleton_thresholds()
    by_name = Map.new(modules, &{&1.name, &1})

    modules
    |> Enum.filter(&(genserver?(&1) and &1.singleton))
    |> Enum.flat_map(fn module ->
      callers = sync_callers(modules, module.name, sync_api_names(module))

      if length(callers) >= thresholds.fan_in do
        [bottleneck_finding(Map.fetch!(by_name, module.name), callers, runtime, thresholds)]
      else
        []
      end
    end)
  end

  # Public function names whose body performs `GenServer.call(__MODULE__, …)`.
  # May be empty: a singleton can expose no wrapper at all and be called
  # directly, which `sync_callers/3` handles separately.
  defp sync_api_names(module) do
    module.functions
    |> Enum.filter(fn {_key, clauses} ->
      Enum.any?(clauses, &(&1.public and calls_self_sync?(&1.body)))
    end)
    |> Enum.map(fn {{name, _arity}, _clauses} -> name end)
    |> MapSet.new()
  end

  # `GenServer.call(__MODULE__, …)` — the self-targeted form the client wrapper
  # uses. `render_alias/1` returns nil for `__MODULE__`, which is why these are
  # (correctly) absent from the inter-process subgraph but are exactly what
  # marks a function as synchronous API here.
  defp calls_self_sync?(body) do
    {_ast, found} =
      Macro.prewalk(body, false, fn
        {{:., _, [{:__aliases__, _, [:GenServer]}, fun]}, _meta,
         [{:__MODULE__, _, ctx} | _rest]} = node,
        _acc
        when fun in [:call, :multi_call] and is_atom(ctx) ->
          {node, true}

        node, acc ->
          {node, acc}
      end)

    found
  end

  # Both forms of synchronous load count, and the union matters:
  #
  #   * via the client wrapper — `Store.fetch(k)`, which internally calls the
  #     process. This is the dominant idiom, and measuring only the raw call
  #     site misses it entirely (a false negative on essentially all real code).
  #   * direct — `GenServer.call(Store, :read)` from another module, which
  #     serialises on the same process without going through any wrapper.
  #
  # A module doing either is one more caller queueing on the singleton.
  defp sync_callers(modules, target, api_functions) do
    modules
    |> Enum.reject(&(&1.name == target))
    |> Enum.filter(fn module ->
      clauses = module.functions |> Map.values() |> List.flatten()

      calls_api?(clauses, target, api_functions) or calls_process_directly?(clauses, module, target)
    end)
    |> Enum.map(& &1.name)
  end

  defp calls_api?(clauses, target, api_functions) do
    MapSet.size(api_functions) > 0 and
      Enum.any?(clauses, fn clause ->
        clause.body
        |> qualified_calls()
        |> Enum.any?(fn {mfa, _line} ->
          case String.split(mfa, ".") do
            [_single] ->
              false

            parts ->
              fun = List.last(parts)
              mod = parts |> Enum.drop(-1) |> Enum.join(".")
              mod == target and MapSet.member?(api_functions, fun)
          end
        end)
      end)
  end

  defp calls_process_directly?(clauses, module, target) do
    Enum.any?(clauses, fn clause ->
      clause.body
      |> genserver_call_sites(module)
      |> Enum.any?(&(&1.to == target))
    end)
  end

  defp bottleneck_finding(module, callers, runtime, thresholds) do
    observed = runtime_for(runtime, module.name)
    confirmed? = confirmed?(observed, thresholds.queue_len)

    %{
      rule: "singleton_bottleneck",
      message: bottleneck_message(module.name, callers, observed, confirmed?, thresholds),
      category: "otp_deep",
      severity: if(confirmed?, do: "error", else: "warning"),
      confidence: if(confirmed?, do: "runtime_confirmed", else: "static"),
      fan_in: length(callers),
      callers: Enum.sort(callers),
      runtime: observed,
      file: module.file,
      line: module.line,
      module: module.name
    }
  end

  defp runtime_for(:unavailable, _name), do: :unavailable

  defp runtime_for(runtime, name) when is_map(runtime) do
    case Map.fetch(runtime, name) do
      {:ok, data} -> Map.put(data, :confirmed, false)
      :error -> :unavailable
    end
  end

  defp confirmed?(:unavailable, _threshold), do: false
  defp confirmed?(%{max_queue_len: len}, threshold), do: len >= threshold
  defp confirmed?(_other, _threshold), do: false

  defp bottleneck_message(name, callers, :unavailable, _confirmed?, _thresholds) do
    "#{name} is a name: __MODULE__ singleton whose synchronous API is called by " <>
      "#{length(callers)} distinct modules — every caller serialises through one process " <>
      "(statically suspected; no runtime data available to confirm)"
  end

  defp bottleneck_message(name, callers, %{max_queue_len: len} = observed, true, thresholds) do
    "#{name} is a singleton called by #{length(callers)} distinct modules AND observed with a " <>
      "message queue of #{len} (threshold #{thresholds.queue_len}) over #{observed.window} " <>
      "snapshots — statically suspected, runtime-confirmed"
  end

  defp bottleneck_message(name, callers, %{max_queue_len: len} = observed, false, _thresholds) do
    "#{name} is a singleton called by #{length(callers)} distinct modules; observed max queue " <>
      "#{len} over #{observed.window} snapshots did not reach the confirmation threshold"
  end

  # Collector ring buffer, joined by registered name. Degrades to :unavailable
  # rather than erroring when no snapshots exist — the monitor role may not be
  # running at all, which is the same graceful-absence contract EmbeddingServing
  # uses for the semantic endpoints.
  defp collector_queue_data do
    if Collector.active?() do
      snapshots = Collector.history(:local, last: 20)

      queues =
        snapshots
        |> Enum.flat_map(&(&1[:top_processes] || []))
        |> Enum.reduce(%{}, fn proc, acc ->
          case proc[:registered_name] || proc[:module] do
            nil ->
              acc

            key ->
              Map.update(acc, key, proc[:message_queue] || 0, &max(&1, proc[:message_queue] || 0))
          end
        end)

      Map.new(queues, fn {name, len} ->
        {name, %{max_queue_len: len, window: length(snapshots)}}
      end)
    else
      :unavailable
    end
  rescue
    # The Collector is optional infrastructure; a bottleneck finding must never
    # fail because runtime telemetry is missing or mid-restart.
    _ -> :unavailable
  end

  # ============================================================================
  # Info-tier heuristics (spec §3.6)
  # ============================================================================
  #
  # The spec placed these in the Tier 2 conventions engine as an `otp_deep` rule
  # family, on the grounds that they need no new machinery. That was written
  # before `Knowledge.Otp` existed; it now IS the machinery, and it owns an
  # endpoint with a uniform `?check=` filter. Splitting the family across two
  # endpoints purely by severity tier would make an agent query two places for
  # one question ("what is wrong with this process architecture?"), so they live
  # here with the rest. Same rule family, same response shape, one surface.

  @doc """
  `GenServer.call/3` with an `:infinity` timeout.

  Legitimate for genuinely long operations, which is why this is info tier and
  not a warning — it is an inventory, not an accusation. Worth having because
  `:infinity` removes the only backstop against a wedged callee: the caller
  blocks forever rather than crashing with a timeout anyone can see.
  """
  @spec infinity_call_timeout([map()]) :: [finding()]
  def infinity_call_timeout(modules) do
    Enum.flat_map(modules, fn module ->
      module.functions
      |> Map.values()
      |> List.flatten()
      |> Enum.flat_map(&infinity_calls(&1.body))
      |> Enum.map(fn line ->
        %{
          rule: "infinity_call_timeout",
          message:
            "GenServer.call with :infinity — the caller blocks indefinitely if the callee " <>
              "wedges, with no timeout to surface it",
          category: "otp_deep",
          severity: "info",
          file: module.file,
          line: line,
          module: module.name
        }
      end)
    end)
  end

  defp infinity_calls(body) do
    {_ast, acc} =
      Macro.prewalk(body, [], fn
        {{:., _, [{:__aliases__, _, [:GenServer]}, :call]}, meta, [_target, _msg, :infinity]} =
            node,
        acc ->
          {node, [meta[:line] || 0 | acc]}

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(acc)
  end

  @doc """
  `:one_for_all` supervisors with more children than the configured maximum.

  Under `:one_for_all` a single child crash restarts every sibling. That is
  occasionally intended, but past a handful of children it is usually
  `:rest_for_one` that was meant, or a split into sub-trees — one unrelated
  crash should not restart a dozen processes.
  """
  @spec one_for_all_amplification([map()], [map()]) :: [finding()]
  def one_for_all_amplification(supervisors, modules) do
    by_name = Map.new(modules, &{&1.name, &1})
    max_children = OtpChecks.one_for_all_max_children()

    supervisors
    |> Enum.filter(&(&1.strategy == "one_for_all" and length(&1.children) > max_children))
    |> Enum.flat_map(fn decl ->
      case Map.get(by_name, decl.module) do
        nil ->
          []

        module ->
          [
            %{
              rule: "one_for_all_amplification",
              message:
                "#{decl.key} uses :one_for_all with #{length(decl.children)} children " <>
                  "(threshold #{max_children}) — one crash restarts all of them; " <>
                  ":rest_for_one or a sub-tree split is usually what was intended",
              category: "otp_deep",
              severity: "info",
              file: module.file,
              line: module.line,
              module: decl.key
            }
          ]
      end
    end)
  end

  @doc """
  `GenServer.start/2,3` or `Agent.start/1,2` where `start_link` was meant.

  An unlinked process is an orphan: it is not part of any supervision tree, so
  nothing restarts it and nothing notices when it dies. Complements the existing
  `unsupervised_task` convention rule.
  """
  @spec unlinked_start([map()]) :: [finding()]
  def unlinked_start(modules) do
    Enum.flat_map(modules, fn module ->
      module.functions
      |> Map.values()
      |> List.flatten()
      |> Enum.flat_map(&unlinked_start_sites(&1.body))
      |> Enum.map(fn {mod, line} ->
        %{
          rule: "unlinked_start",
          message:
            "#{mod}.start/… rather than start_link — the process is unlinked, so it belongs " <>
              "to no supervision tree and nothing restarts or reports it",
          category: "otp_deep",
          severity: "info",
          file: module.file,
          line: line,
          module: module.name
        }
      end)
    end)
  end

  defp unlinked_start_sites(body) do
    {_ast, acc} =
      Macro.prewalk(body, [], fn
        {{:., _, [{:__aliases__, _, [mod]}, :start]}, meta, _args} = node, acc
        when mod in [:GenServer, :Agent] ->
          {node, [{Atom.to_string(mod), meta[:line] || 0} | acc]}

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(acc)
  end

  # ============================================================================
  # Shared parsing
  # ============================================================================

  @doc """
  Parse project sources into the module structures the checks consume.

  Exposed so tests can build the structure from a fixture path without going
  through `Context.Store`.
  """
  @spec parse_modules(%{String.t() => map()}) :: [map()]
  def parse_modules(all_asts) do
    all_asts
    |> Map.keys()
    |> Enum.flat_map(&modules_in_file/1)
  end

  defp modules_in_file(path) do
    with {:ok, source} <- File.read(path),
         {:ok, ast} <- Code.string_to_quoted(source) do
      ast
      |> module_nodes()
      |> Enum.map(fn {name, line, body} ->
        %{
          name: name,
          file: path,
          line: line,
          uses: uses_in(body),
          singleton: singleton?(body),
          functions: functions_in(body)
        }
      end)
    else
      _ -> []
    end
  end

  defp module_nodes(ast) do
    {_ast, acc} =
      Macro.prewalk(ast, [], fn
        {:defmodule, meta, [alias_ast, body_kw]} = node, acc when is_list(body_kw) ->
          case {render_alias(alias_ast), Keyword.fetch(body_kw, :do)} do
            {nil, _} -> {node, acc}
            {_name, :error} -> {node, acc}
            {name, {:ok, body}} -> {node, [{name, meta[:line] || 0, body} | acc]}
          end

        node, acc ->
          {node, acc}
      end)

    acc
  end

  # `use GenServer` / `@behaviour GenServer` — either marks a process module.
  defp uses_in(body) do
    {_ast, acc} =
      Macro.prewalk(body, [], fn
        {:use, _meta, [alias_ast | _]} = node, acc ->
          {node, [render_alias(alias_ast) | acc]}

        {:@, _meta, [{:behaviour, _, [alias_ast]}]} = node, acc ->
          {node, [render_alias(alias_ast) | acc]}

        node, acc ->
          {node, acc}
      end)

    acc |> Enum.reject(&is_nil/1) |> Enum.uniq()
  end

  defp process_module?(%{uses: uses}), do: Enum.any?(uses, &(&1 in @behaviour_aliases))

  defp genserver?(%{uses: uses}), do: "GenServer" in uses

  # `name: __MODULE__` anywhere in the module — the universal idiom for a
  # singleton process whose module identity IS its process identity. This is
  # what lets a cycle be reported at `high` confidence: for a singleton, one
  # module means exactly one process, so a module-level cycle is a process-level
  # deadlock. Without it, multiple instances may make the same cycle harmless.
  defp singleton?(body) do
    {_ast, found} =
      Macro.prewalk(body, false, fn
        {:name, {:__MODULE__, _, ctx}} = node, _acc when is_atom(ctx) -> {node, true}
        node, acc -> {node, acc}
      end)

    found
  end

  # `%{{name, arity} => [clause]}` — a clause carries its args, body, line and
  # whether it is guarded, which is all the checks need.
  defp functions_in(body) do
    {_ast, clauses} =
      Macro.prewalk(body, [], fn
        {kind, meta, [head, body_kw]} = node, acc
        when kind in [:def, :defp] and is_list(body_kw) ->
          case {parse_head(head), Keyword.fetch(body_kw, :do)} do
            {nil, _} ->
              {node, acc}

            {_, :error} ->
              {node, acc}

            {{name, args, guarded?}, {:ok, fn_body}} ->
              clause = %{
                args: args,
                body: fn_body,
                line: meta[:line] || 0,
                guarded: guarded?,
                public: kind == :def
              }

              {node, [{{name, length(args)}, clause} | acc]}
          end

        node, acc ->
          {node, acc}
      end)

    clauses
    |> Enum.reverse()
    |> Enum.group_by(fn {key, _} -> key end, fn {_, clause} -> clause end)
  end

  # `def foo(a, b) when guard` wraps the head in `:when`.
  defp parse_head({:when, _meta, [inner_head, _guard]}) do
    case parse_head(inner_head) do
      {name, args, _} -> {name, args, true}
      nil -> nil
    end
  end

  defp parse_head({name, _meta, args}) when is_atom(name) and is_list(args) do
    {Atom.to_string(name), args, false}
  end

  defp parse_head({name, _meta, nil}) when is_atom(name), do: {Atom.to_string(name), [], false}
  defp parse_head(_other), do: nil

  # `Mod.fun(...)` → {"Mod.fun", line}. Erlang modules render with their colon
  # so `:timer.sleep` stays distinguishable from a `Timer.sleep` alias.
  defp qualified_calls(body) do
    {_ast, acc} =
      Macro.prewalk(body, [], fn
        {{:., _, [mod_ast, fun]}, meta, _args} = node, acc when is_atom(fun) ->
          case render_call_module(mod_ast) do
            nil -> {node, acc}
            mod -> {node, [{"#{mod}.#{fun}", meta[:line] || 0} | acc]}
          end

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(acc)
  end

  # Local calls, for the intra-module helper closure.
  defp unqualified_calls(body) do
    {_ast, acc} =
      Macro.prewalk(body, [], fn
        {name, _meta, args} = node, acc when is_atom(name) and is_list(args) ->
          {node, [{Atom.to_string(name), length(args)} | acc]}

        node, acc ->
          {node, acc}
      end)

    Enum.uniq(acc)
  end

  defp render_call_module({:__aliases__, _, _} = alias_ast), do: render_alias(alias_ast)
  defp render_call_module(mod) when is_atom(mod), do: inspect(mod)
  defp render_call_module(_other), do: nil

  defp render_alias({:__aliases__, _meta, parts}) do
    if Enum.all?(parts, &is_atom/1), do: Enum.join(parts, "."), else: nil
  end

  defp render_alias(atom) when is_atom(atom) and not is_nil(atom), do: inspect(atom)
  defp render_alias(_other), do: nil

  # ============================================================================
  # Filtering
  # ============================================================================

  defp filter_by_check(findings, nil), do: findings
  defp filter_by_check(findings, check), do: Enum.filter(findings, &(&1.rule == check))

  defp apply_suppressions(findings, suppress) when suppress == %{}, do: findings

  defp apply_suppressions(findings, suppress) do
    Enum.reject(findings, fn finding ->
      case Map.fetch(suppress, finding.rule) do
        {:ok, modules} -> finding.module in modules
        :error -> false
      end
    end)
  end

  defp sort_groups(groups) do
    groups
    |> Enum.sort_by(fn {_check, findings} -> -length(findings) end)
    |> Map.new()
  end
end
