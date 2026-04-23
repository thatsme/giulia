defprotocol Giulia.Fixtures.Serializable do
  @moduledoc """
  Protocol declaration. Extraction should recognize this as a
  distinct structure from `defmodule` — `defprotocol` expands to
  a module but the callbacks are the contract, not plain functions.

  Historical context: `defprotocol` used to surface as just another
  module with a few odd functions. Any future refactor that tightens
  protocol handling will diff against this fixture.
  """

  @type t :: term()

  @doc "Encode a term into its serialized form."
  @spec encode(t()) :: binary()
  def encode(term)

  @doc "Estimate the byte size without fully encoding."
  @spec byte_size_hint(t()) :: non_neg_integer()
  def byte_size_hint(term)
end

defimpl Giulia.Fixtures.Serializable, for: BitString do
  @moduledoc "BitString implementation of the Serializable protocol."

  def encode(bin), do: bin

  def byte_size_hint(bin), do: byte_size(bin)
end

defimpl Giulia.Fixtures.Serializable, for: Integer do
  def encode(n), do: Integer.to_string(n)

  def byte_size_hint(n), do: n |> Integer.to_string() |> byte_size()
end
