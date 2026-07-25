defmodule Giulia.Knowledge.OtpInfoTest do
  use ExUnit.Case, async: true

  alias Giulia.Knowledge.{Otp, Supervision}

  describe "infinity_call_timeout" do
    test "fires on GenServer.call with :infinity" do
      source = """
      defmodule Slow.Client do
        def load, do: GenServer.call(Slow.Server, :load, :infinity)
      end
      """

      assert [finding] = source |> parse() |> Otp.infinity_call_timeout()
      assert finding.rule == "infinity_call_timeout"
      assert finding.severity == "info"
    end

    test "does not fire on a default or numeric timeout" do
      source = """
      defmodule Fine.Client do
        def a, do: GenServer.call(Fine.Server, :x)
        def b, do: GenServer.call(Fine.Server, :x, 30_000)
      end
      """

      assert source |> parse() |> Otp.infinity_call_timeout() == []
    end
  end

  describe "unlinked_start" do
    test "fires on GenServer.start and Agent.start" do
      source = """
      defmodule Orphan.Maker do
        def a, do: GenServer.start(Orphan.Server, %{})
        def b, do: Agent.start(fn -> %{} end)
      end
      """

      findings = source |> parse() |> Otp.unlinked_start()

      assert length(findings) == 2
      assert Enum.all?(findings, &(&1.severity == "info"))
    end

    test "does not fire on start_link" do
      source = """
      defmodule Linked.Maker do
        def a, do: GenServer.start_link(Linked.Server, %{})
        def b, do: Agent.start_link(fn -> %{} end)
      end
      """

      assert source |> parse() |> Otp.unlinked_start() == []
    end
  end

  describe "one_for_all_amplification" do
    test "fires when :one_for_all exceeds the configured child count" do
      children = Enum.map_join(1..7, ",\n    ", &"Amp.Child#{&1}")

      source = """
      defmodule Amp.Application do
        use Application

        def start(_type, _args) do
          children = [
            #{children}
          ]

          Supervisor.start_link(children, strategy: :one_for_all, name: Amp.Supervisor)
        end
      end
      """

      assert [finding] = analyze(source)
      assert finding.rule == "one_for_all_amplification"
      assert finding.severity == "info"
      assert finding.message =~ "7 children"
    end

    test "does not fire at or below the threshold" do
      children = Enum.map_join(1..4, ",\n    ", &"Small.Child#{&1}")

      source = """
      defmodule Small.Application do
        use Application

        def start(_type, _args) do
          children = [
            #{children}
          ]

          Supervisor.start_link(children, strategy: :one_for_all, name: Small.Supervisor)
        end
      end
      """

      assert analyze(source) == []
    end

    test "does not fire for :one_for_one however many children" do
      children = Enum.map_join(1..12, ",\n    ", &"Many.Child#{&1}")

      source = """
      defmodule Many.Application do
        use Application

        def start(_type, _args) do
          children = [
            #{children}
          ]

          Supervisor.start_link(children, strategy: :one_for_one, name: Many.Supervisor)
        end
      end
      """

      assert analyze(source) == []
    end
  end

  # one_for_all_amplification needs both the supervision declarations and the
  # parsed modules (declarations carry no file/line of their own).
  defp analyze(source) do
    with_source(source, fn path ->
      modules = Otp.parse_modules(%{path => %{}})
      supervisors = Supervision.extract(%{path => %{}})
      Otp.one_for_all_amplification(supervisors, modules)
    end)
  end

  defp parse(source), do: with_source(source, &Otp.parse_modules(%{&1 => %{}}))

  defp with_source(source, fun) do
    path = Path.join(System.tmp_dir!(), "otp_info_#{System.unique_integer([:positive])}.ex")
    File.write!(path, source)

    try do
      fun.(path)
    after
      File.rm(path)
    end
  end
end
