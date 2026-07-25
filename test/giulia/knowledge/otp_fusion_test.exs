defmodule Giulia.Knowledge.OtpFusionTest do
  use ExUnit.Case, async: true

  alias Giulia.Knowledge.Otp

  # A singleton whose synchronous API is the idiomatic client wrapper, called by
  # `caller_count` distinct modules. This is the shape essentially every real
  # Elixir GenServer has, and the shape the first Phase 3 implementation could
  # not see.
  defp singleton_with_callers(caller_count) do
    callers =
      for i <- 1..caller_count do
        """
        defmodule Client#{i} do
          def go, do: Hot.Store.fetch(:a)
        end
        """
      end

    """
    defmodule Hot.Store do
      use GenServer

      def start_link(_), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

      def fetch(key), do: GenServer.call(__MODULE__, {:fetch, key})
      def peek(key), do: :ets.lookup(:cache, key)

      def handle_call({:fetch, k}, _from, s), do: {:reply, Map.get(s, k), s}
    end

    #{Enum.join(callers, "\n")}
    """
  end

  describe "fan-in measured at the synchronous API surface" do
    test "counts modules calling the client wrapper, not GenServer.call sites" do
      # The regression this guards: measuring at `GenServer.call(Target, ...)`
      # makes the target always `__MODULE__`, so fan-in is structurally zero and
      # the check silently never fires.
      assert [finding] = 8 |> singleton_with_callers() |> parse() |> Otp.singleton_bottleneck(:unavailable)

      assert finding.module == "Hot.Store"
      assert finding.fan_in == 8
      assert finding.callers == Enum.map(1..8, &"Client#{&1}")
    end

    test "does not fire below the threshold" do
      assert 3 |> singleton_with_callers() |> parse() |> Otp.singleton_bottleneck(:unavailable) == []
    end

    test "calls to non-synchronous functions do not count toward fan-in" do
      # `peek/1` reads ETS directly and never queues on the process.
      callers =
        for i <- 1..8 do
          """
          defmodule Client#{i} do
            def go, do: Hot.Store.peek(:a)
          end
          """
        end

      source = """
      defmodule Hot.Store do
        use GenServer
        def start_link(_), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
        def fetch(key), do: GenServer.call(__MODULE__, {:fetch, key})
        def peek(key), do: :ets.lookup(:cache, key)
        def handle_call({:fetch, k}, _from, s), do: {:reply, Map.get(s, k), s}
      end

      #{Enum.join(callers, "\n")}
      """

      assert source |> parse() |> Otp.singleton_bottleneck(:unavailable) == []
    end

    test "a non-singleton is not a bottleneck however high its fan-in" do
      source =
        8
        |> singleton_with_callers()
        |> String.replace("GenServer.start_link(__MODULE__, %{}, name: __MODULE__)", "GenServer.start_link(__MODULE__, %{})")

      assert source |> parse() |> Otp.singleton_bottleneck(:unavailable) == []
    end
  end

  describe "runtime fusion" do
    setup do
      %{modules: 8 |> singleton_with_callers() |> parse()}
    end

    test "runtime queue above threshold escalates to error", %{modules: modules} do
      runtime = %{"Hot.Store" => %{max_queue_len: 250, window: 20}}

      assert [finding] = Otp.singleton_bottleneck(modules, runtime)
      assert finding.severity == "error"
      assert finding.confidence == "runtime_confirmed"
      assert finding.runtime.max_queue_len == 250
      assert finding.message =~ "runtime-confirmed"
    end

    test "runtime queue below threshold stays a warning", %{modules: modules} do
      runtime = %{"Hot.Store" => %{max_queue_len: 3, window: 20}}

      assert [finding] = Otp.singleton_bottleneck(modules, runtime)
      assert finding.severity == "warning"
      assert finding.confidence == "static"
      assert finding.message =~ "did not reach the confirmation threshold"
    end

    test "no runtime data degrades gracefully rather than erroring", %{modules: modules} do
      assert [finding] = Otp.singleton_bottleneck(modules, :unavailable)

      assert finding.runtime == :unavailable
      assert finding.severity == "warning"
      assert finding.message =~ "no runtime data available"
    end

    test "runtime data for other processes does not confirm this one", %{modules: modules} do
      runtime = %{"Some.Other.Server" => %{max_queue_len: 5_000, window: 20}}

      assert [finding] = Otp.singleton_bottleneck(modules, runtime)
      assert finding.runtime == :unavailable
      assert finding.severity == "warning"
    end
  end

  defp parse(source) do
    path = Path.join(System.tmp_dir!(), "otp_fusion_#{System.unique_integer([:positive])}.ex")
    File.write!(path, source)

    try do
      Otp.parse_modules(%{path => %{}})
    after
      File.rm(path)
    end
  end
end
