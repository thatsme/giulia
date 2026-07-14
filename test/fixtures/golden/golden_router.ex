# Pass 9 (router dispatch): bare Phoenix-style route DSL — deliberately NOT
# real Plug/Phoenix (no dep in the fidelity contract). Pass 9 matches the
# AST shape `verb path, Alias, :action` against DispatchInvariants
# router_verbs; nothing needs to compile or be loaded.
#   => Golden.Router -> Golden.HealthController.check/2 {:calls, :router_dispatch}
# Pass 6 (references): the controller alias in the route args (module-to-MFA
# dispatch edges don't suppress module-level references)
#   => Golden.Router -> Golden.HealthController :references
defmodule Golden.Router do
  get "/health", Golden.HealthController, :check
end
