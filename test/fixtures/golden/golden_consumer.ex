# Pass 2 (:depends_on): explicit alias
#   => Golden.Consumer -> Golden.Util :depends_on
# Pass 4 (:alias_resolved): short-form call through the alias
#   => Golden.Consumer.run/1 -> Golden.Util.normalize/1 {:calls, :alias_resolved}
# Pass 5: promotion suppressed — module edge (:depends_on) already exists.
defmodule Golden.Consumer do
  alias Golden.Util

  def run(value), do: Util.normalize(value)
end
