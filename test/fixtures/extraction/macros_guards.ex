defmodule Giulia.Fixtures.MacrosAndGuards do
  @moduledoc """
  Covers `defmacro` / `defmacrop` / `defguard` / `defguardp` extraction
  against plain `def` / `defp`. Each has a distinct `type` atom in
  `function_info` and different downstream semantics (macros expand
  at compile time; guards have a restricted expression subset).
  """

  @doc "Public macro that expands to a debug call."
  defmacro debug_call(label) do
    quote do
      IO.inspect(unquote(label), label: "debug")
    end
  end

  @doc false
  defmacrop internal_wrap(expr) do
    quote do
      result = unquote(expr)
      {:ok, result}
    end
  end

  @doc "Public guard — usable in `when` clauses."
  defguard is_tiny_int(n) when is_integer(n) and n >= 0 and n < 100

  @doc false
  defguardp is_tuple_pair(t) when is_tuple(t) and tuple_size(t) == 2

  # Regular def that uses the guards above.
  @spec classify(integer()) :: :tiny | :large
  def classify(n) when is_tiny_int(n), do: :tiny
  def classify(_n), do: :large

  # Regular def that wraps an expression via the private macro.
  def safe_parse(input) do
    internal_wrap(Integer.parse(input))
  end

  # Bang + predicate names to keep Step 1 regression class covered.
  @spec must_be_pair!(tuple()) :: tuple()
  def must_be_pair!(t) when is_tuple_pair(t), do: t
  def must_be_pair!(_), do: raise(ArgumentError, "not a pair")

  @spec trivial?(any()) :: boolean()
  def trivial?(x), do: x in [nil, :none, false, 0, ""]
end
