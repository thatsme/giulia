# Pass 6 (references): explicit FULL-name module atom in a function body.
# The inverse guard of golden_config.ex — a real reference to the project's
# own *.Application module (the mix.exs `mod:` analog) must survive the
# stdlib-collision fix, because direct project-set membership wins before
# the loadable-runtime check.
#   => Golden.Release -> Golden.Application :references
defmodule Golden.Release do
  def app_module, do: Golden.Application
end
