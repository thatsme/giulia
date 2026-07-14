# KNOWN BUG, pinned as-is (found by this golden's maiden run, 2026-07-14):
# the defdelegate pass SHOULD emit Golden.Facade -> Golden.Util :depends_on,
# but `extract_defdelegate_targets/2` (builder.ex) pattern-matches the plain
# keyword shape `[to: {:__aliases__, ...}]` while the pass parses with
# Sourceror, which wraps keyword keys in {:__block__, _, [:to]} — the match
# never fires on real input. Pass 6 catches the alias as a fallback:
#   => Golden.Facade -> Golden.Util :references   (CURRENT, buggy label)
# On compiled projects xref (Pass 3) masks this by emitting call edges;
# on uncompiled projects (typical third-party analysis) defdelegate deps
# degrade to :references. When the matcher is fixed, this golden MUST be
# updated to :depends_on in the same commit — that update is the fix's test.
defmodule Golden.Facade do
  defdelegate normalize(value), to: Golden.Util
end
