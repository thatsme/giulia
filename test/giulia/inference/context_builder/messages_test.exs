defmodule Giulia.Inference.ContextBuilder.MessagesTest do
  use ExUnit.Case, async: true

  alias Giulia.Inference.ContextBuilder.Messages

  # ============================================================================
  # count_recent_thinks/1
  # ============================================================================

  describe "count_recent_thinks/1" do
    test "counts consecutive thinks from start" do
      history = [
        {"think", %{}, {:ok, "thinking..."}},
        {"think", %{}, {:ok, "still thinking..."}},
        {"read_file", %{}, {:ok, "content"}}
      ]

      assert Messages.count_recent_thinks(history) == 2
    end

    test "returns 0 when no thinks at start" do
      history = [
        {"read_file", %{}, {:ok, "content"}},
        {"think", %{}, {:ok, "thinking..."}}
      ]

      assert Messages.count_recent_thinks(history) == 0
    end

    test "returns 0 for empty history" do
      assert Messages.count_recent_thinks([]) == 0
    end
  end

  # ============================================================================
  # inject_distilled_context/2
  # ============================================================================

  describe "inject_distilled_context/2" do
    test "returns messages unchanged when no action history" do
      messages = [%{role: "user", content: "hello"}]
      state = %{action_history: []}

      assert Messages.inject_distilled_context(messages, state) == messages
    end

    test "appends context to last user message" do
      messages = [
        %{role: "system", content: "system"},
        %{role: "user", content: "do something"}
      ]

      state = %{
        action_history: [{"read_file", %{"path" => "lib/foo.ex"}, {:ok, "content"}}],
        counters: %{iteration: 2, max_iterations: 50},
        project_path: nil
      }

      result = Messages.inject_distilled_context(messages, state)
      last = List.last(result)
      assert last.content =~ "[CONTEXT REMINDER]"
      assert last.content =~ "Iteration: 2/50"
    end

    test "adds new user message when last isn't user role" do
      messages = [
        %{role: "system", content: "system"},
        %{role: "assistant", content: "response"}
      ]

      state = %{
        action_history: [{"think", %{}, {:ok, "hmm"}}],
        counters: %{iteration: 1, max_iterations: 50},
        project_path: nil
      }

      result = Messages.inject_distilled_context(messages, state)
      assert length(result) == 3
      assert List.last(result).role == "user"
    end
  end
end
