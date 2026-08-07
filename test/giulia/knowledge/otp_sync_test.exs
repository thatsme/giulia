defmodule Giulia.Knowledge.OtpSyncTest do
  use ExUnit.Case, async: true

  alias Giulia.Knowledge.Otp

  # ==========================================================================
  # cross_process_call_cycle — the feature's reason to exist
  # ==========================================================================

  describe "cross_process_call_cycle" do
    test "two GenServers calling each other in handle_call is a high-confidence cycle" do
      # THE deliberate deadlock fixture. A blocks on B while B blocks on A;
      # both die by timeout. Both are name: __MODULE__ singletons, so module
      # identity is process identity and the cycle is certain, not suspected.
      source = """
      defmodule Dead.A do
        use GenServer

        def start_link(_), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

        def handle_call(:fetch, _from, state) do
          {:reply, GenServer.call(Dead.B, :need_it), state}
        end
      end

      defmodule Dead.B do
        use GenServer

        def start_link(_), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

        def handle_call(:need_it, _from, state) do
          {:reply, GenServer.call(Dead.A, :fetch), state}
        end
      end
      """

      assert [finding] = source |> parse() |> Otp.cross_process_call_cycle()

      assert finding.rule == "cross_process_call_cycle"
      assert finding.confidence == "high"
      assert finding.severity == "error"
      assert Enum.sort(finding.cycle) == ["Dead.A", "Dead.B"]
    end

    test "a cycle through client API wrappers is detected" do
      # THE false negative this detector shipped with. Neither callback contains
      # a `GenServer.call` — both call the other module's client wrapper, which
      # is how essentially all real Elixir expresses a cross-process call.
      #
      # Measured across Giulia, Plug, Bandit and Plausible: 72 GenServer.call
      # sites, ZERO inside a callback. Without this the subgraph is empty on
      # every real codebase, and an empty graph reports as "no cycles found".
      source = """
      defmodule Wrap.A do
        use GenServer

        def start_link(_), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
        def fetch, do: GenServer.call(__MODULE__, :fetch)

        def handle_call(:fetch, _from, state) do
          {:reply, Wrap.B.lookup(), state}
        end
      end

      defmodule Wrap.B do
        use GenServer

        def start_link(_), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
        def lookup, do: GenServer.call(__MODULE__, :lookup)

        def handle_call(:lookup, _from, state) do
          {:reply, Wrap.A.fetch(), state}
        end
      end
      """

      assert [finding] = source |> parse() |> Otp.cross_process_call_cycle()
      assert finding.confidence == "high"
      assert finding.severity == "error"
      assert Enum.sort(finding.cycle) == ["Wrap.A", "Wrap.B"]
    end

    test "calling a non-synchronous function of another server is not an edge" do
      # `peek/0` reads ETS directly — no process boundary, so no deadlock risk.
      source = """
      defmodule Safe.A do
        use GenServer
        def start_link(_), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
        def fetch, do: GenServer.call(__MODULE__, :fetch)
        def handle_call(:fetch, _from, s), do: {:reply, Safe.B.peek(), s}
      end

      defmodule Safe.B do
        use GenServer
        def start_link(_), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
        def peek, do: :ets.lookup(:t, :k)
        def lookup, do: GenServer.call(__MODULE__, :lookup)
        def handle_call(:lookup, _from, s), do: {:reply, Safe.A.fetch(), s}
      end
      """

      assert source |> parse() |> Otp.cross_process_call_cycle() == []
    end

    test "medium confidence when an endpoint is not a singleton" do
      source = """
      defmodule Dead.A do
        use GenServer
        def start_link(_), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
        def handle_call(:fetch, _from, s), do: {:reply, GenServer.call(Dead.B, :x), s}
      end

      defmodule Dead.B do
        use GenServer
        def start_link(_), do: GenServer.start_link(__MODULE__, %{})
        def handle_call(:x, _from, s), do: {:reply, GenServer.call(Dead.A, :fetch), s}
      end
      """

      assert [finding] = source |> parse() |> Otp.cross_process_call_cycle()
      assert finding.confidence == "medium"
      assert finding.severity == "warning"
    end

    test "calls outside a callback do not close a cycle" do
      # Only a call made while already inside a process can deadlock it. A
      # public API function calling out is just a client call.
      source = """
      defmodule Safe.A do
        use GenServer
        def start_link(_), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
        def fetch, do: GenServer.call(Safe.B, :x)
        def handle_call(:ping, _from, s), do: {:reply, :pong, s}
      end

      defmodule Safe.B do
        use GenServer
        def start_link(_), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
        def handle_call(:x, _from, s), do: {:reply, GenServer.call(Safe.A, :ping), s}
      end
      """

      assert source |> parse() |> Otp.cross_process_call_cycle() == []
    end

    test "self-calls are not cycles" do
      source = """
      defmodule Solo do
        use GenServer
        def start_link(_), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
        def handle_call(:a, _from, s), do: {:reply, GenServer.call(Solo, :b), s}
      end
      """

      assert source |> parse() |> Otp.cross_process_call_cycle() == []
    end

    test "non-literal targets are skipped rather than guessed" do
      source = """
      defmodule Dyn.A do
        use GenServer
        def start_link(_), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
        def handle_call({:to, pid}, _from, s), do: {:reply, GenServer.call(pid, :x), s}
      end
      """

      assert source |> parse() |> Otp.cross_process_call_cycle() == []
    end
  end

  # ==========================================================================
  # sync_call_chain_depth
  # ==========================================================================

  describe "sync_call_chain_depth" do
    test "flags a 3-hop chain with the summed timeout budget" do
      source = """
      defmodule Chain.A do
        use GenServer
        def handle_call(:go, _from, s), do: {:reply, GenServer.call(Chain.B, :go), s}
      end

      defmodule Chain.B do
        use GenServer
        def handle_call(:go, _from, s), do: {:reply, GenServer.call(Chain.C, :go), s}
      end

      defmodule Chain.C do
        use GenServer
        def handle_call(:go, _from, s), do: {:reply, GenServer.call(Chain.D, :go), s}
      end

      defmodule Chain.D do
        use GenServer
        def handle_call(:go, _from, s), do: {:reply, :ok, s}
      end
      """

      assert [finding] = source |> parse() |> Otp.sync_call_chain_depth()

      assert finding.chain == ["Chain.A", "Chain.B", "Chain.C", "Chain.D"]
      # Three hops at the 5s default.
      assert finding.timeout_budget_ms == 15_000
    end

    test "explicit per-hop timeouts are summed, not assumed" do
      source = """
      defmodule T.A do
        use GenServer
        def handle_call(:go, _from, s), do: {:reply, GenServer.call(T.B, :go, 30_000), s}
      end

      defmodule T.B do
        use GenServer
        def handle_call(:go, _from, s), do: {:reply, GenServer.call(T.C, :go, 1_000), s}
      end

      defmodule T.C do
        use GenServer
        def handle_call(:go, _from, s), do: {:reply, GenServer.call(T.D, :go), s}
      end

      defmodule T.D do
        use GenServer
        def handle_call(:go, _from, s), do: {:reply, :ok, s}
      end
      """

      assert [finding] = source |> parse() |> Otp.sync_call_chain_depth()
      assert finding.timeout_budget_ms == 36_000
    end

    test "a 2-hop chain is under the configured threshold" do
      source = """
      defmodule Short.A do
        use GenServer
        def handle_call(:go, _from, s), do: {:reply, GenServer.call(Short.B, :go), s}
      end

      defmodule Short.B do
        use GenServer
        def handle_call(:go, _from, s), do: {:reply, GenServer.call(Short.C, :go), s}
      end

      defmodule Short.C do
        use GenServer
        def handle_call(:go, _from, s), do: {:reply, :ok, s}
      end
      """

      assert source |> parse() |> Otp.sync_call_chain_depth() == []
    end
  end

  # ==========================================================================
  # singleton_bottleneck
  # ==========================================================================

  describe "singleton_bottleneck" do
    test "fires when a singleton is called by at least the threshold of modules" do
      callers =
        for i <- 1..8 do
          """
          defmodule Caller#{i} do
            use GenServer
            def handle_call(:go, _from, s), do: {:reply, GenServer.call(Hot.Store, :read), s}
          end
          """
        end

      source = """
      defmodule Hot.Store do
        use GenServer
        def start_link(_), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
        def handle_call(:read, _from, s), do: {:reply, s, s}
      end

      #{Enum.join(callers, "\n")}
      """

      assert [finding] = source |> parse() |> Otp.singleton_bottleneck()
      assert finding.module == "Hot.Store"
      assert finding.fan_in == 8
      assert finding.confidence == "static"
    end

    test "does not fire below the threshold" do
      callers =
        for i <- 1..3 do
          """
          defmodule Caller#{i} do
            use GenServer
            def handle_call(:go, _from, s), do: {:reply, GenServer.call(Warm.Store, :read), s}
          end
          """
        end

      source = """
      defmodule Warm.Store do
        use GenServer
        def start_link(_), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
        def handle_call(:read, _from, s), do: {:reply, s, s}
      end

      #{Enum.join(callers, "\n")}
      """

      assert source |> parse() |> Otp.singleton_bottleneck() == []
    end

    test "a non-singleton with high fan-in is not a bottleneck" do
      # Without name: __MODULE__ there may be many instances, so callers do not
      # necessarily serialise through one process.
      callers =
        for i <- 1..8 do
          """
          defmodule Caller#{i} do
            use GenServer
            def handle_call(:go, _from, s), do: {:reply, GenServer.call(Pooled.Worker, :read), s}
          end
          """
        end

      source = """
      defmodule Pooled.Worker do
        use GenServer
        def start_link(_), do: GenServer.start_link(__MODULE__, %{})
        def handle_call(:read, _from, s), do: {:reply, s, s}
      end

      #{Enum.join(callers, "\n")}
      """

      assert source |> parse() |> Otp.singleton_bottleneck() == []
    end
  end

  defp parse(source) do
    path = Path.join(System.tmp_dir!(), "otp_sync_#{System.unique_integer([:positive])}.ex")
    File.write!(path, source)

    try do
      Otp.parse_modules(%{path => %{}})
    after
      File.rm(path)
    end
  end
end
