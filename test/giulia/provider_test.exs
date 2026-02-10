defmodule Giulia.ProviderTest do
  @moduledoc """
  Tests for Giulia.Provider — behaviour definition and dispatch.
  """
  use ExUnit.Case, async: true

  alias Giulia.Provider

  # ============================================================================
  # current/0
  # ============================================================================

  describe "current/0" do
    test "returns a module" do
      result = Provider.current()
      assert is_atom(result)
    end

    test "defaults to Anthropic when no config set" do
      # The default in provider.ex is Giulia.Provider.Anthropic
      assert Provider.current() == Giulia.Provider.Anthropic
    end
  end

  # ============================================================================
  # Behaviour callbacks exist
  # ============================================================================

  describe "behaviour" do
    setup do
      Code.ensure_loaded!(Giulia.Provider)
      :ok
    end

    test "defines callback attributes" do
      callbacks = Giulia.Provider.__info__(:attributes)
                  |> Keyword.get_values(:callback)
                  |> List.flatten()

      assert is_list(callbacks)
    end

    test "module exports current/0" do
      assert function_exported?(Giulia.Provider, :current, 0)
    end

    test "module exports chat/1 and chat/2" do
      assert function_exported?(Giulia.Provider, :chat, 1)
      assert function_exported?(Giulia.Provider, :chat, 2)
    end

    test "module exports chat_with_tools/3" do
      assert function_exported?(Giulia.Provider, :chat_with_tools, 3)
    end
  end
end
