defmodule Giulia.Config.DispatchInvariantsTest do
  use ExUnit.Case, async: true

  alias Giulia.Config.DispatchInvariants

  test "current/0 loads the JSON config and exposes the four expected keys" do
    cfg = DispatchInvariants.current()

    assert is_map(cfg)
    assert is_list(cfg.project_markers)
    assert is_struct(cfg.implicit_functions, MapSet)
    assert is_map(cfg.known_behaviour_callbacks)
    assert is_list(cfg.router_verbs)
  end

  test "current/0 is stable — repeated calls return identical persistent_term" do
    a = DispatchInvariants.current()
    b = DispatchInvariants.current()
    assert a == b
  end

  test "project_markers/0 contains the universal Mix marker" do
    markers = DispatchInvariants.project_markers()
    assert "mix.exs" in markers
    assert Enum.all?(markers, &is_binary/1)
  end

  test "implicit_functions/0 covers the GenServer callbacks (no false-dead-code on init/1)" do
    impl = DispatchInvariants.implicit_functions()
    assert MapSet.member?(impl, {"init", 1})
    assert MapSet.member?(impl, {"handle_call", 3})
    assert MapSet.member?(impl, {"handle_cast", 2})
    refute MapSet.member?(impl, {"definitely_not_a_callback", 0})
  end

  test "known_behaviours/0 covers the major frameworks" do
    names = DispatchInvariants.known_behaviours()
    for required <- ["GenServer", "Plug", "Phoenix.LiveView", "Ecto.Type", "Oban.Worker"] do
      assert required in names, "expected #{required} in known_behaviours/0"
    end
  end

  test "callbacks_for/1 returns atom/arity pairs for known behaviours" do
    callbacks = DispatchInvariants.callbacks_for("GenServer")
    assert {:init, 1} in callbacks
    assert {:handle_call, 3} in callbacks
    assert Enum.all?(callbacks, fn {name, arity} -> is_atom(name) and is_integer(arity) end)
  end

  test "callbacks_for/1 returns [] for an unknown behaviour" do
    assert DispatchInvariants.callbacks_for("Definitely.Not.A.Behaviour") == []
  end

  test "known_behaviour?/1 distinguishes known vs unknown" do
    assert DispatchInvariants.known_behaviour?("GenServer")
    refute DispatchInvariants.known_behaviour?("Definitely.Not.A.Behaviour")
  end

  test "router_verbs/0 covers the seven Phoenix HTTP verbs as atoms" do
    verbs = DispatchInvariants.router_verbs()
    assert Enum.sort(verbs) == Enum.sort([:get, :post, :put, :patch, :delete, :head, :options])
  end

  test "router_verb?/1 accepts the canonical verbs and rejects arbitrary atoms" do
    assert DispatchInvariants.router_verb?(:get)
    assert DispatchInvariants.router_verb?(:patch)
    refute DispatchInvariants.router_verb?(:resources)
    refute DispatchInvariants.router_verb?(:plug)
  end

  test "reload/0 returns a structurally equivalent map" do
    original = DispatchInvariants.current()
    reloaded = DispatchInvariants.reload()
    assert Map.keys(original) == Map.keys(reloaded)
    assert original == reloaded
  end
end
