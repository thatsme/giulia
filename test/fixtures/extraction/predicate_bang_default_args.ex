defmodule Giulia.Fixtures.PredicateBangDefaultArgs do
  @moduledoc """
  Covers the two Step 1 extraction regressions:

  - Predicate functions (`?` suffix) and bang functions (`!` suffix)
    were dropped by a regex that only accepted `\\w+` — `?` and `!`
    are not word characters.
  - Default args produce multiple arities at extraction time
    (`def foo(x, y \\\\ :default)` emits both `foo/1` and `foo/2`),
    and earlier passes tracked only the max arity.

  Both have regression tests; this fixture freezes the extraction
  output so a future refactor that silently changes the arity list,
  reorders functions, or drops the `?`/`!` suffix gets surfaced as
  a diff to the golden file.
  """

  @spec valid?(any()) :: boolean()
  def valid?(x), do: is_integer(x) and x > 0

  @spec has_key?(map(), atom()) :: boolean()
  def has_key?(m, k), do: Map.has_key?(m, k)

  @spec get!(map(), atom()) :: any()
  def get!(m, k), do: Map.fetch!(m, k)

  @spec put!(map(), atom(), any()) :: map()
  def put!(m, k, v), do: Map.put(m, k, v)

  # Default-arg cascade: greet/1 and greet/2 both exist.
  @spec greet(String.t(), String.t()) :: String.t()
  def greet(name, greeting \\ "Hello"), do: "#{greeting}, #{name}!"

  # Triple default arg: configure/1, configure/2, configure/3.
  def configure(mod, opts \\ [], timeout \\ 5_000) do
    {mod, opts, timeout}
  end

  # Private predicate and bang — extraction should still surface
  # these with type: :defp.
  defp can_proceed?(state), do: state != :halted
  defp must_retry!(err), do: raise(RuntimeError, inspect(err))

  # defdelegate has its own arity story — pin it.
  defdelegate delegated_check(x), to: String, as: :valid?
end
