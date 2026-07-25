defmodule Giulia.Knowledge.OtpTest do
  use ExUnit.Case, async: true

  alias Giulia.Knowledge.Otp

  # ==========================================================================
  # blocking_init — DROP side, parametric over each config tier
  # ==========================================================================

  describe "blocking_init drops (must fire)" do
    for {label, call} <- [
          {"network", "Req.get(\"https://example.com\")"},
          {"erlang network", ":gen_tcp.connect(~c\"h\", 80, [])"},
          {"db driver", "Postgrex.query!(conn, \"SELECT 1\", [])"},
          {"repo convention", "MyApp.Repo.all(Thing)"},
          {"nested repo convention", "MyApp.Tenant.Repo.one(Thing)"},
          {"cross-process", "GenServer.call(Other, :fetch)"},
          {"task await", "Task.await(task)"},
          {"sleep", "Process.sleep(100)"},
          {"erlang sleep", ":timer.sleep(100)"}
        ] do
      test "fires on #{label}" do
        findings = blocking_findings(genserver_with_init(unquote(call)))

        assert [finding] = findings
        assert finding.rule == "blocking_init"
        assert finding.severity == "error"
        assert finding.module == "Fix.Server"
      end
    end

    test "fires through the intra-module private-helper closure" do
      source = """
      defmodule Fix.Server do
        use GenServer

        def init(_arg) do
          {:ok, load_config()}
        end

        defp load_config, do: fetch_remote()
        defp fetch_remote, do: Req.get("https://example.com")
      end
      """

      assert [finding] = blocking_findings(source)
      assert finding.message =~ "Req.get"
    end

    test "File.* is warning tier, not error" do
      assert [finding] = blocking_findings(genserver_with_init("File.read!(\"config.json\")"))
      assert finding.severity == "warning"
    end
  end

  # ==========================================================================
  # blocking_init — PASS side, strictly larger than the drop set
  # ==========================================================================

  describe "blocking_init passes (must not fire)" do
    test "plain module with no OTP behaviour" do
      source = """
      defmodule Fix.Plain do
        def init(_arg), do: Req.get("https://example.com")
      end
      """

      assert blocking_findings(source) == []
    end

    test "blocking call outside init/1" do
      source = """
      defmodule Fix.Server do
        use GenServer

        def init(_arg), do: {:ok, %{}}
        def handle_call(:fetch, _from, state), do: {:reply, Req.get("https://x"), state}
      end
      """

      assert blocking_findings(source) == []
    end

    test "GenServer with no init/1 at all" do
      source = """
      defmodule Fix.Server do
        use GenServer
        def handle_call(:ping, _from, state), do: {:reply, :pong, state}
      end
      """

      assert blocking_findings(source) == []
    end

    test "non-blocking work in init/1" do
      source = """
      defmodule Fix.Server do
        use GenServer

        def init(arg) do
          {:ok, %{started_at: System.monotonic_time(), arg: Map.new(arg)}}
        end
      end
      """

      assert blocking_findings(source) == []
    end

    test "helper defined but never reached from init/1" do
      source = """
      defmodule Fix.Server do
        use GenServer

        def init(_arg), do: {:ok, %{}}
        defp unused_helper, do: Req.get("https://example.com")
      end
      """

      assert blocking_findings(source) == []
    end

    test "a module whose name merely contains Repo is not a repo call" do
      # `repo_convention` matches a final segment of exactly "Repo".
      assert blocking_findings(genserver_with_init("RepoHelper.all(Thing)")) == []
    end
  end

  describe "blocking_init finding content" do
    test "suggests handle_continue when the module lacks it" do
      assert [finding] = blocking_findings(genserver_with_init("Req.get(\"https://x\")"))
      assert finding.message =~ "handle_continue"
      assert finding.message =~ "{:continue, :load}"
    end

    test "notes handle_continue as possibly deliberate when present" do
      source = """
      defmodule Fix.Server do
        use GenServer

        def init(_arg), do: Req.get("https://x")
        def handle_continue(:load, state), do: {:noreply, state}
      end
      """

      assert [finding] = blocking_findings(source)
      assert finding.message =~ "may be deliberate"
    end
  end

  # ==========================================================================
  # missing_catch_all_handle_info
  # ==========================================================================

  describe "missing_catch_all_handle_info drops (must fire)" do
    test "clauses exist, none catch-all" do
      source = """
      defmodule Fix.Server do
        use GenServer

        def handle_info(:tick, state), do: {:noreply, state}
        def handle_info({:reply, _}, state), do: {:noreply, state}
      end
      """

      assert [finding] = handle_info_findings(source)
      assert finding.rule == "missing_catch_all_handle_info"
      assert finding.message =~ "2 handle_info/2 clause(s)"
    end

    test "a guarded bare-variable head is not a catch-all" do
      # The guard is exactly what makes it selective — an unmatched message
      # still crashes the server.
      source = """
      defmodule Fix.Server do
        use GenServer

        def handle_info(msg, state) when is_tuple(msg), do: {:noreply, state}
      end
      """

      assert [_finding] = handle_info_findings(source)
    end

    test "@behaviour GenServer counts as a process module" do
      source = """
      defmodule Fix.Server do
        @behaviour GenServer
        def handle_info(:tick, state), do: {:noreply, state}
      end
      """

      assert [_finding] = handle_info_findings(source)
    end
  end

  describe "missing_catch_all_handle_info passes (must not fire)" do
    test "no handle_info at all keeps the injected default" do
      source = """
      defmodule Fix.Server do
        use GenServer
        def handle_call(:ping, _from, state), do: {:reply, :pong, state}
      end
      """

      assert handle_info_findings(source) == []
    end

    test "underscore catch-all present" do
      source = """
      defmodule Fix.Server do
        use GenServer

        def handle_info(:tick, state), do: {:noreply, state}
        def handle_info(_other, state), do: {:noreply, state}
      end
      """

      assert handle_info_findings(source) == []
    end

    test "named bare-variable catch-all present" do
      source = """
      defmodule Fix.Server do
        use GenServer

        def handle_info(:tick, state), do: {:noreply, state}
        def handle_info(msg, state), do: {:noreply, Map.put(state, :last, msg)}
      end
      """

      assert handle_info_findings(source) == []
    end

    test "non-OTP module with handle_info-shaped functions" do
      source = """
      defmodule Fix.Plain do
        def handle_info(:tick, state), do: {:noreply, state}
      end
      """

      assert handle_info_findings(source) == []
    end
  end

  # ==========================================================================
  # Helpers
  # ==========================================================================

  defp genserver_with_init(call) do
    """
    defmodule Fix.Server do
      use GenServer

      def init(_arg) do
        #{call}
        {:ok, %{}}
      end
    end
    """
  end

  defp blocking_findings(source), do: source |> parse() |> Otp.blocking_init()

  defp handle_info_findings(source),
    do: source |> parse() |> Otp.missing_catch_all_handle_info()

  defp parse(source) do
    path = Path.join(System.tmp_dir!(), "otp_#{System.unique_integer([:positive])}.ex")
    File.write!(path, source)

    try do
      Otp.parse_modules(%{path => %{}})
    after
      File.rm(path)
    end
  end
end
