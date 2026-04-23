defmodule Giulia.Fixtures.Outer do
  @moduledoc """
  Module with a nested inner module. Tests whether extraction
  surfaces `Outer.Inner` as a distinct module entry (with its own
  functions) or flattens it into the outer's extraction.

  Historical note: the extractor currently treats each
  `defmodule` block as a top-level module, so `Outer.Inner` should
  appear as a separate module entry alongside `Outer`. Functions
  defined INSIDE `Outer.Inner` should NOT be attributed to the
  outer module. This fixture pins the current behaviour so any
  refactor that nests differently produces a visible diff.
  """

  def outer_only_fn, do: :outer

  defmodule Inner do
    @moduledoc "Inner module nested inside Outer."

    def inner_only_fn, do: :inner

    def shared_name, do: :from_inner
  end

  # Same function name as Inner.shared_name/0 but in the outer
  # module. After extraction, both `Outer.shared_name/0` and
  # `Outer.Inner.shared_name/0` should exist as distinct entries
  # (different modules), not get deduplicated.
  def shared_name, do: :from_outer
end

# A second top-level module that nests one more level deep.
defmodule Giulia.Fixtures.Triple do
  defmodule Mid do
    defmodule Leaf do
      @moduledoc "Leaf at three nesting levels — pins triple-nested extraction."

      def deep, do: :leaf
    end
  end
end
