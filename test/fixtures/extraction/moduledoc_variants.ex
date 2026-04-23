defmodule Giulia.Fixtures.ModuledocHeredoc do
  @moduledoc """
  Heredoc form.

  Multi-line content with embedded `quoted tokens` and **markdown**.
  The extractor must preserve the string content verbatim.
  """

  def run, do: :ok
end

defmodule Giulia.Fixtures.ModuledocSingleLine do
  @moduledoc "Single-line string form."

  def run, do: :ok
end

defmodule Giulia.Fixtures.ModuledocFalse do
  @moduledoc false

  # `@moduledoc false` is a deliberate opt-out signal — distinct from
  # a missing @moduledoc. Extraction must preserve `false`, not
  # collapse to `nil`. See commit 979e0ff / extraction_test.exs.
  def run, do: :ok
end

defmodule Giulia.Fixtures.ModuledocMissing do
  # No @moduledoc at all — extraction must return nil.
  def run, do: :ok
end

defmodule Giulia.Fixtures.ModuledocSigilS do
  @moduledoc ~S"""
  Sigil_S form — no interpolation, preserves #{literals}.
  """

  def run, do: :ok
end
