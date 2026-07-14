# Protocol definition — dispatch edges are synthesized from the defimpl
# side (golden_proto_impl.ex), not here.
defprotocol Golden.Proto do
  def render(value)
end
