defmodule Giulia.Prompt.BuilderTest do
  @moduledoc """
  Tests for Prompt.Builder — prompt construction and model tier detection.

  Tests pure functions only. Functions that call Registry.list_tools/0
  or Store are skipped (they require named GenServers).
  """
  use ExUnit.Case, async: true

  alias Giulia.Prompt.Builder

  # ============================================================================
  # detect_model_tier/1 (string → tier)
  # ============================================================================

  describe "detect_model_tier/1" do
    test "small model: 3B" do
      assert :small = Builder.detect_model_tier("qwen2.5-coder-3b-instruct")
    end

    test "small model: 7B" do
      assert :small = Builder.detect_model_tier("codellama-7b")
    end

    test "medium model: 14B" do
      assert :medium = Builder.detect_model_tier("qwen/qwen2.5-coder-14b")
    end

    test "medium model: 8B" do
      assert :medium = Builder.detect_model_tier("llama-8b-instruct")
    end

    test "large model: 32B" do
      assert :large = Builder.detect_model_tier("qwen2.5-32b")
    end

    test "large model: 70B" do
      assert :large = Builder.detect_model_tier("llama-70b")
    end

    test "unknown size defaults to medium" do
      assert :medium = Builder.detect_model_tier("some-model-without-size")
    end

    test "non-binary input defaults to medium" do
      assert :medium = Builder.detect_model_tier(nil)
    end

    test "case insensitive: 14B vs 14b" do
      assert :medium = Builder.detect_model_tier("Model-14B-Instruct")
    end

    test "boundary: 16B is medium" do
      assert :medium = Builder.detect_model_tier("model-16b")
    end

    test "boundary: 17B is large" do
      assert :large = Builder.detect_model_tier("model-17b")
    end
  end

  # ============================================================================
  # format_observation/2
  # ============================================================================

  describe "format_observation/2" do
    test "success with string content" do
      result = Builder.format_observation("read_file", {:ok, "file contents here"})
      assert String.contains?(result, "read_file")
      assert String.contains?(result, "succeeded")
      assert String.contains?(result, "file contents here")
    end

    test "success with non-string content is inspected" do
      result = Builder.format_observation("search_code", {:ok, %{matches: 5}})
      assert String.contains?(result, "search_code")
      assert String.contains?(result, "matches")
    end

    test "truncates content over 2000 chars" do
      long_content = String.duplicate("x", 3000)
      result = Builder.format_observation("read_file", {:ok, long_content})
      assert String.contains?(result, "truncated")
      assert String.length(result) < 3000
    end

    test "does not truncate content under 2000 chars" do
      short_content = String.duplicate("x", 100)
      result = Builder.format_observation("read_file", {:ok, short_content})
      refute String.contains?(result, "truncated")
    end

    test "error :enoent gives file not found message" do
      result = Builder.format_observation("read_file", {:error, :enoent})
      assert String.contains?(result, "File not found")
    end

    test "error :sandbox_violation gives access denied message" do
      result = Builder.format_observation("read_file", {:error, :sandbox_violation})
      assert String.contains?(result, "Access denied")
      assert String.contains?(result, "sandbox")
    end

    test "error :missing_path_parameter gives missing path message" do
      result = Builder.format_observation("read_file", {:error, :missing_path_parameter})
      assert String.contains?(result, "Missing")
      assert String.contains?(result, "path")
    end

    test "generic error includes tool name and reason" do
      result = Builder.format_observation("edit_file", {:error, "something broke"})
      assert String.contains?(result, "edit_file")
      assert String.contains?(result, "failed")
    end
  end

  # ============================================================================
  # build_tiered_prompt/2 — dispatch
  # ============================================================================

  describe "build_tiered_prompt/2 dispatch" do
    # These require Registry to be running, but we can test that
    # the function is exported and accepts the right args
    test "function is exported" do
      assert function_exported?(Builder, :build_tiered_prompt, 2)
    end
  end

  # ============================================================================
  # extract_module_mentions (private, tested via build_focused_context)
  # ============================================================================

  # extract_module_mentions and extract_file_mentions are private,
  # but we can indirectly test them through the public API.
  # Since build_focused_context needs Store, we test the patterns directly
  # by checking the regex behavior.

  describe "module mention patterns" do
    test "CamelCase words are detected as module mentions" do
      # The regex ~r/[A-Z][a-zA-Z0-9]*(?:\.[A-Z][a-zA-Z0-9]*)*/ should match
      matches = Regex.scan(~r/[A-Z][a-zA-Z0-9]*(?:\.[A-Z][a-zA-Z0-9]*)*/,
                           "Fix Giulia.Tools.Registry")
      flat = List.flatten(matches)
      assert "Giulia.Tools.Registry" in flat
      assert "Fix" in flat
    end

    test "file path patterns are detected" do
      matches = Regex.scan(~r/[\w\/]+\.(?:ex|exs)/, "look at lib/giulia/client.ex")
      flat = List.flatten(matches)
      assert "lib/giulia/client.ex" in flat
    end
  end

  # ============================================================================
  # build_transaction_section — tested via build_system_prompt indirectly
  # ============================================================================

  describe "transaction section patterns" do
    test "build_system_prompt/1 is exported" do
      # Ensure module is loaded before checking exports
      Code.ensure_loaded!(Builder)
      assert function_exported?(Builder, :build_system_prompt, 1)
    end
  end

  # ============================================================================
  # clear_model_tier_cache/0
  # ============================================================================

  describe "clear_model_tier_cache/0" do
    test "returns :ok" do
      assert :ok = Builder.clear_model_tier_cache()
    end

    test "clears cached tier" do
      Application.put_env(:giulia, :detected_model_tier, :small)
      Builder.clear_model_tier_cache()
      assert nil == Application.get_env(:giulia, :detected_model_tier)
    end

    test "clears cached model name" do
      Application.put_env(:giulia, :detected_model_name, "test-model")
      Builder.clear_model_tier_cache()
      assert nil == Application.get_env(:giulia, :detected_model_name)
    end
  end

  # ============================================================================
  # add_observation/3
  # ============================================================================

  describe "add_observation/3" do
    test "appends observation to message list" do
      messages = [%{role: "system", content: "sys"}, %{role: "user", content: "hello"}]
      result = Builder.add_observation(messages, "read_file", {:ok, "contents"})
      assert length(result) == 3
      last = List.last(result)
      assert last.role == "assistant"
      assert String.contains?(last.content, "read_file")
    end

    test "formats error observation" do
      messages = []
      result = Builder.add_observation(messages, "write_file", {:error, :enoent})
      [msg] = result
      assert String.contains?(msg.content, "File not found")
    end
  end
end
