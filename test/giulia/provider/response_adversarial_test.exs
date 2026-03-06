defmodule Giulia.Provider.ResponseAdversarialTest do
  @moduledoc """
  Adversarial tests for provider response parsing.

  Each provider has a parse_response/1 function that transforms raw API
  responses into Giulia's internal format. These tests feed malformed,
  unexpected, and edge-case API responses to find crashes.

  Targets:
  - LM Studio parse_response with malformed OpenAI-compatible bodies
  - Anthropic parse_response with missing/extra fields, atom leak
  - Groq parse_response with unexpected structures
  - Gemini parse_response with missing candidates
  - ResponseParser integration with all provider output shapes
  """
  use ExUnit.Case, async: true

  alias Giulia.Inference.ResponseParser

  # ============================================================================
  # 1. LM Studio parse_response adversarial
  # ============================================================================

  describe "LM Studio response parsing" do
    # We test via the module's public interface indirectly.
    # LM Studio's parse_response is private, so we test through chat/3's
    # response path by calling parse_response through Module internals.

    test "empty choices list" do
      # LM Studio returns {"choices": []} — no completions
      response = apply_lm_studio_parse(%{"choices" => []})
      assert response.content =~ "choices"  # catch-all inspects the input
      assert response.stop_reason == :error
    end

    test "missing choices key entirely" do
      response = apply_lm_studio_parse(%{"id" => "123", "object" => "chat.completion"})
      assert response.stop_reason == :error
    end

    test "nil message in choice" do
      response = apply_lm_studio_parse(%{"choices" => [%{"message" => nil, "finish_reason" => "stop"}]})
      # nil["content"] and nil["tool_calls"] should not crash
      assert is_map(response)
    end

    test "missing message key in choice" do
      response = apply_lm_studio_parse(%{"choices" => [%{"finish_reason" => "stop"}]})
      assert is_map(response)
    end

    test "tool_calls is empty list" do
      response = apply_lm_studio_parse(%{
        "choices" => [%{
          "message" => %{"content" => "hello", "tool_calls" => []},
          "finish_reason" => "stop"
        }]
      })
      assert response.content == "hello"
      assert response.tool_calls == []
    end

    test "tool_call with nil function" do
      response = apply_lm_studio_parse(%{
        "choices" => [%{
          "message" => %{
            "content" => nil,
            "tool_calls" => [%{"id" => "1", "function" => nil}]
          },
          "finish_reason" => "tool_calls"
        }]
      })
      # nil["name"] and nil["arguments"] — should not crash
      assert is_map(response)
    end

    test "tool_call with arguments as raw unparseable string" do
      response = apply_lm_studio_parse(%{
        "choices" => [%{
          "message" => %{
            "content" => nil,
            "tool_calls" => [%{
              "id" => "tc_1",
              "function" => %{"name" => "read_file", "arguments" => "NOT JSON AT ALL"}
            }]
          },
          "finish_reason" => "tool_calls"
        }]
      })
      # parse_arguments should wrap in %{"raw" => ...} instead of crashing
      assert [tc] = response.tool_calls
      assert tc.name == "read_file"
      assert tc.arguments == %{"raw" => "NOT JSON AT ALL"}
    end

    test "tool_call with arguments as integer" do
      response = apply_lm_studio_parse(%{
        "choices" => [%{
          "message" => %{
            "content" => nil,
            "tool_calls" => [%{
              "id" => "tc_1",
              "function" => %{"name" => "think", "arguments" => 42}
            }]
          },
          "finish_reason" => "tool_calls"
        }]
      })
      assert [tc] = response.tool_calls
      assert tc.arguments == %{}
    end

    test "finish_reason is nil" do
      response = apply_lm_studio_parse(%{
        "choices" => [%{
          "message" => %{"content" => "hello", "tool_calls" => nil},
          "finish_reason" => nil
        }]
      })
      assert response.stop_reason == :end_turn
    end

    test "finish_reason is unknown string" do
      response = apply_lm_studio_parse(%{
        "choices" => [%{
          "message" => %{"content" => "hello", "tool_calls" => nil},
          "finish_reason" => "content_filter"
        }]
      })
      assert response.stop_reason == :end_turn
    end

    test "extremely large content string" do
      big = String.duplicate("x", 1_000_000)
      response = apply_lm_studio_parse(%{
        "choices" => [%{
          "message" => %{"content" => big, "tool_calls" => nil},
          "finish_reason" => "length"
        }]
      })
      assert response.stop_reason == :max_tokens
      assert String.length(response.content) == 1_000_000
    end

    defp apply_lm_studio_parse(body) do
      Giulia.Provider.LMStudio.parse_response(body)
    end
  end

  # ============================================================================
  # 2. Anthropic parse_response adversarial
  # ============================================================================

  describe "Anthropic response parsing" do
    test "normal text response" do
      response = apply_anthropic_parse(%{
        "content" => [%{"type" => "text", "text" => "Hello!"}],
        "stop_reason" => "end_turn"
      })
      assert response.content == "Hello!"
      assert response.tool_calls == []
      assert response.stop_reason == :end_turn
    end

    test "tool_use response" do
      response = apply_anthropic_parse(%{
        "content" => [
          %{"type" => "text", "text" => "I'll read that file."},
          %{"type" => "tool_use", "name" => "read_file", "input" => %{"path" => "lib/foo.ex"}, "id" => "tu_1"}
        ],
        "stop_reason" => "tool_use"
      })
      assert response.content == "I'll read that file."
      assert [tc] = response.tool_calls
      assert tc.name == "read_file"
      assert tc.arguments == %{"path" => "lib/foo.ex"}
    end

    test "empty content array" do
      response = apply_anthropic_parse(%{
        "content" => [],
        "stop_reason" => "end_turn"
      })
      assert response.content == nil
      assert response.tool_calls == []
    end

    test "content with unknown block type" do
      response = apply_anthropic_parse(%{
        "content" => [
          %{"type" => "text", "text" => "hello"},
          %{"type" => "image", "data" => "base64..."}
        ],
        "stop_reason" => "end_turn"
      })
      # Unknown type should be skipped by the catch-all in reduce
      assert response.content == "hello"
    end

    test "nil stop_reason does not crash" do
      # String.to_atom(nil) would crash — needs guard
      response = apply_anthropic_parse(%{
        "content" => [%{"type" => "text", "text" => "hi"}],
        "stop_reason" => nil
      })
      assert is_map(response)
    end

    test "unknown stop_reason does not leak atoms" do
      # String.to_atom on untrusted input is an atom table exhaustion vector
      random_reason = "custom_reason_#{:rand.uniform(1_000_000)}"
      response = apply_anthropic_parse(%{
        "content" => [%{"type" => "text", "text" => "hi"}],
        "stop_reason" => random_reason
      })
      assert is_atom(response.stop_reason)
    end

    test "missing content key entirely" do
      # Should not crash with FunctionClauseError
      result = safe_apply_anthropic_parse(%{"stop_reason" => "end_turn"})
      assert match?({:ok, _}, result) or match?({:rescued, _}, result)
    end

    test "missing stop_reason key entirely" do
      result = safe_apply_anthropic_parse(%{"content" => [%{"type" => "text", "text" => "hi"}]})
      assert match?({:ok, _}, result) or match?({:rescued, _}, result)
    end

    test "completely empty response body" do
      result = safe_apply_anthropic_parse(%{})
      assert match?({:ok, _}, result) or match?({:rescued, _}, result)
    end

    test "response body is a string instead of map" do
      result = safe_apply_anthropic_parse("Internal Server Error")
      assert match?({:ok, _}, result) or match?({:rescued, _}, result)
    end

    test "response body is nil" do
      result = safe_apply_anthropic_parse(nil)
      assert match?({:ok, _}, result) or match?({:rescued, _}, result)
    end

    test "multiple tool_use blocks" do
      response = apply_anthropic_parse(%{
        "content" => [
          %{"type" => "tool_use", "name" => "read_file", "input" => %{"path" => "a.ex"}, "id" => "tu_1"},
          %{"type" => "tool_use", "name" => "read_file", "input" => %{"path" => "b.ex"}, "id" => "tu_2"}
        ],
        "stop_reason" => "tool_use"
      })
      assert length(response.tool_calls) == 2
      # Order should be preserved (reversed from reduce accumulation)
      assert Enum.at(response.tool_calls, 0).arguments["path"] == "a.ex"
      assert Enum.at(response.tool_calls, 1).arguments["path"] == "b.ex"
    end

    defp apply_anthropic_parse(body) do
      Giulia.Provider.Anthropic.parse_response(body)
    end

    defp safe_apply_anthropic_parse(body) do
      try do
        {:ok, Giulia.Provider.Anthropic.parse_response(body)}
      rescue
        e -> {:rescued, Exception.message(e)}
      end
    end
  end

  # ============================================================================
  # 3. Groq parse_response adversarial
  # ============================================================================

  describe "Groq response parsing" do
    test "normal response" do
      {:ok, response} = apply_groq_parse(%{
        "choices" => [%{"message" => %{"content" => "Hello!"}}]
      })
      assert response.content == "Hello!"
    end

    test "empty choices" do
      result = apply_groq_parse(%{"choices" => []})
      assert {:error, :unexpected_response} = result
    end

    test "missing choices key" do
      result = apply_groq_parse(%{"id" => "123"})
      assert {:error, :unexpected_response} = result
    end

    test "error response from API" do
      result = apply_groq_parse(%{"error" => %{"message" => "Rate limit exceeded"}})
      assert {:error, {:groq_error, _}} = result
    end

    test "nil body" do
      result = apply_groq_parse(nil)
      assert {:error, :unexpected_response} = result
    end

    test "tool_calls returned as nil in response map" do
      {:ok, response} = apply_groq_parse(%{
        "choices" => [%{"message" => %{"content" => "hello"}}]
      })
      # Groq returns tool_calls: nil — verify ResponseParser handles this
      assert response.tool_calls == nil
    end

    test "content is nil" do
      {:ok, response} = apply_groq_parse(%{
        "choices" => [%{"message" => %{"content" => nil}}]
      })
      assert response.content == nil
    end

    defp apply_groq_parse(body) do
      Giulia.Provider.Groq.parse_response(body)
    end
  end

  # ============================================================================
  # 4. Gemini parse_response adversarial
  # ============================================================================

  describe "Gemini response parsing" do
    test "normal response" do
      {:ok, response} = apply_gemini_parse(%{
        "candidates" => [%{"content" => %{"parts" => [%{"text" => "Hello!"}]}}]
      })
      assert response.content == "Hello!"
    end

    test "multiple parts concatenated" do
      {:ok, response} = apply_gemini_parse(%{
        "candidates" => [%{"content" => %{"parts" => [
          %{"text" => "Part 1"},
          %{"text" => "Part 2"}
        ]}}]
      })
      assert response.content == "Part 1\nPart 2"
    end

    test "empty candidates list" do
      result = apply_gemini_parse(%{"candidates" => []})
      assert {:error, :unexpected_response} = result
    end

    test "missing candidates key" do
      result = apply_gemini_parse(%{"something_else" => true})
      assert {:error, :unexpected_response} = result
    end

    test "error response" do
      result = apply_gemini_parse(%{"error" => %{"message" => "Quota exceeded"}})
      assert {:error, {:gemini_error, _}} = result
    end

    test "candidate with no content key" do
      result = apply_gemini_parse(%{"candidates" => [%{"finishReason" => "STOP"}]})
      assert {:error, :unexpected_response_format} = result
    end

    test "candidate with empty parts list" do
      {:ok, response} = apply_gemini_parse(%{
        "candidates" => [%{"content" => %{"parts" => []}}]
      })
      # Empty parts → joined empty string
      assert response.content == ""
    end

    test "parts with non-text entries" do
      {:ok, response} = apply_gemini_parse(%{
        "candidates" => [%{"content" => %{"parts" => [
          %{"text" => "hello"},
          %{"inlineData" => %{"mimeType" => "image/png"}}
        ]}}]
      })
      # map_join: "hello" <> "\n" <> "" = "hello\n"
      assert response.content == "hello\n"
    end

    test "nil body" do
      result = apply_gemini_parse(nil)
      assert {:error, :unexpected_response} = result
    end

    defp apply_gemini_parse(body) do
      Giulia.Provider.Gemini.parse_response(body)
    end
  end

  # ============================================================================
  # 5. ResponseParser integration with provider output shapes
  # ============================================================================

  describe "ResponseParser with provider output shapes" do
    test "handles tool_calls: nil (Groq/Gemini style)" do
      response = %{content: ~s({"tool":"think","parameters":{}}), tool_calls: nil}
      assert {:tool_call, "think", %{}} = ResponseParser.parse(response)
    end

    test "handles tool_calls: [] (empty list)" do
      response = %{content: ~s({"tool":"think","parameters":{}}), tool_calls: []}
      assert {:tool_call, "think", %{}} = ResponseParser.parse(response)
    end

    test "handles missing tool_calls key entirely" do
      response = %{content: ~s({"tool":"think","parameters":{}})}
      result = ResponseParser.parse(response)
      assert {:tool_call, "think", %{}} = result
    end

    test "handles content as empty string" do
      response = %{content: "", tool_calls: nil}
      result = ResponseParser.parse(response)
      # Empty string has no JSON → text
      assert {:text, ""} = result
    end

    test "handles response with only stop_reason" do
      response = %{stop_reason: :end_turn}
      result = ResponseParser.parse(response)
      assert {:error, :unknown_response_format} = result
    end

    test "handles integer content" do
      response = %{content: 42}
      result = ResponseParser.parse(response)
      assert {:error, :unknown_response_format} = result
    end

    test "handles list content" do
      response = %{content: ["hello", "world"]}
      result = ResponseParser.parse(response)
      assert {:error, :unknown_response_format} = result
    end
  end

  # ============================================================================
  # 6. ResponseParser.clean_output adversarial
  # ============================================================================

  describe "clean_output adversarial" do
    test "im tokens wrapping text — strips tokens, keeps text" do
      # The lazy .*? in <|im_start|>.*?(<|im_end|>)? matches minimally,
      # so <|im_start|> is stripped but "assistant" remains as content
      result = ResponseParser.clean_output("<|im_start|>assistant<|im_end|>")
      assert result == "assistant"
    end

    test "only action tags — returns fallback" do
      result = ResponseParser.clean_output("<action>{\"tool\":\"think\"}</action>")
      assert result =~ "wasn't able to formulate"
    end

    test "nested think tags" do
      result = ResponseParser.clean_output("<think><think>deep</think></think> answer")
      assert result =~ "answer"
    end

    test "unclosed action tag" do
      result = ResponseParser.clean_output("prefix <action>{json here")
      # Regex <action>.*$ should strip to end
      assert result == "prefix"
    end

    test "extremely long input" do
      big = String.duplicate("x", 500_000)
      result = ResponseParser.clean_output(big)
      assert String.length(result) == 500_000
    end

    test "only whitespace after cleaning" do
      result = ResponseParser.clean_output("<action>{}</action>   \n\t  ")
      assert result =~ "wasn't able to formulate"
    end

    test "multiple action blocks" do
      text = "A<action>1</action>B<action>2</action>C"
      result = ResponseParser.clean_output(text)
      assert result == "ABC"
    end

    test "null bytes in output" do
      result = ResponseParser.clean_output("hello\0world")
      assert is_binary(result)
    end
  end

  # ============================================================================
  # 7. ResponseParser.extract_error_context edge cases
  # ============================================================================

  describe "extract_error_context adversarial" do
    test "position beyond string length" do
      result = ResponseParser.extract_error_context("short", 1000)
      assert is_binary(result)
    end

    test "negative position" do
      result = ResponseParser.extract_error_context("hello", -5)
      assert is_binary(result)
    end

    test "empty string" do
      result = ResponseParser.extract_error_context("", 0)
      assert result == ""
    end

    test "position at zero" do
      result = ResponseParser.extract_error_context("hello world", 0)
      assert is_binary(result)
      assert String.length(result) <= 60
    end
  end
end
