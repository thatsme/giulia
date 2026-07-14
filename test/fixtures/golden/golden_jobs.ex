# Pass 10 (function-reference forms), one edge per form:
#   => Golden.Jobs.spec/0 -> Golden.Util.normalize/1 {:calls, :mfa_ref}
#   => Golden.Jobs.hook/0 -> Golden.Util.normalize/1 {:calls, :capture_ref}
#   => Golden.Jobs.kick/0 -> Golden.Util.normalize/1 {:calls, :apply_ref}
# ORDER SUBTLETY (module level): Pass 10 runs AFTER Pass 5 promotion, so
# these MFA edges never promote. The module-level edge comes from Pass 6
# seeing the Golden.Util aliases in the bodies:
#   => Golden.Jobs -> Golden.Util :references   (NOT {:calls, :promoted})
defmodule Golden.Jobs do
  def spec, do: {Golden.Util, :normalize, [:x]}

  def hook, do: &Golden.Util.normalize/1

  def kick, do: apply(Golden.Util, :normalize, [:x])
end
