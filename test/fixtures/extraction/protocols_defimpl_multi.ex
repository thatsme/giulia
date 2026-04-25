defprotocol Giulia.Fixtures.MultiSerializable do
  @moduledoc """
  Protocol with multi-type defimpl. Elixir compiles
  `defimpl X, for: [T1, T2, T3]` to three independent impl modules
  X.T1, X.T2, X.T3 — extraction must surface all three.
  """

  def encode(term)
end

defimpl Giulia.Fixtures.MultiSerializable, for: [Integer, BitString, Float] do
  @moduledoc "Numeric/string fast-path implementation."

  def encode(x), do: x
end

defimpl Giulia.Fixtures.MultiSerializable, for: Atom do
  def encode(a), do: Atom.to_string(a)
end
