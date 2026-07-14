# Pass 7 (protocol dispatch): defimpl module is named "<Proto>.<Type>"
#   => Golden.Proto -> Golden.Proto.Golden.Data.render/1 {:calls, :protocol_impl}
# Pass 6 (references): the defimpl head's aliases
#   => Golden.Proto.Golden.Data -> Golden.Proto :references
#   => Golden.Proto.Golden.Data -> Golden.Data  :references
defimpl Golden.Proto, for: Golden.Data do
  def render(value), do: value
end
