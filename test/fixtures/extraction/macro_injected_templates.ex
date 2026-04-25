defmodule Giulia.Fixtures.UseHost do
  @moduledoc """
  Defines a `use` macro that injects template functions into consumers.
  The `def adapter/0` and `def changeset/1` declarations inside the
  `quote do ... end` block are templates — they will be created in
  modules that do `use Giulia.Fixtures.UseHost`. Slice E3 says they
  must NOT be attributed to UseHost itself, otherwise the surface
  area is overstated and the templates look like dead code.
  """

  defmacro __using__(_) do
    quote do
      @adapter :default

      def adapter, do: @adapter
      def changeset(attrs), do: {:ok, attrs}
    end
  end

  # Real owned function — should still be extracted as belonging to UseHost.
  def real_helper(x), do: x * 2
end

defmodule Giulia.Fixtures.UseConsumer do
  @moduledoc "Consumer of UseHost. Has its own `actual_def/0`."

  use Giulia.Fixtures.UseHost

  def actual_def, do: :consumer_owned
end
