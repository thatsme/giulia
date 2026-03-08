# AFTER_PULL.md — Post-Pull Distribution Checklist

After pulling changes from the Giulia repository, run this checklist to ensure
system-wide files are up to date. These files live outside the repo and must be
manually distributed.

---

## System-Wide Files

All global files live in `~/.claude/` (`C:\Users\Alessio\.claude\` on this machine).

### 1. SKILL.md — API Endpoint Reference

| Source (repo) | Destination (global) |
|---|---|
| `SKILL.md` | `~/.claude/SKILL.md` |

**What it does:** Tells Claude Code in ANY project folder how to discover and
call Giulia's REST API. Port selection, path conventions, endpoint categories.

**Verify after copy:**
- Port selection table is present (worker:4000, monitor:4001)
- All `${PORT}` placeholders are intact (not hardcoded)
- Path convention says `<CWD>` not a hardcoded path

```bash
cp SKILL.md ~/.claude/SKILL.md
```

### 2. REPORT_RULES.md — Report Generation Rules

| Source (repo) | Destination (global) | Destination (priv) |
|---|---|---|
| `REPORT_RULES.md` | `~/.claude/REPORT_RULES.md` | `priv/REPORT_RULES.md` |

**What it does:** Defines the mandatory procedure for generating analysis reports.
Section order, scoring formulas, formatting rules, and the Elixir Idiom Rule.

**Verify after copy:**
- Elixir Idiom Rule section is present (no OOP/Java framing)
- Anti-pattern #9 (no OOP framing) exists
- Struct Lifecycle section says "coupling metric" not "encapsulation violation"

```bash
cp REPORT_RULES.md ~/.claude/REPORT_RULES.md
cp REPORT_RULES.md priv/REPORT_RULES.md
```

### 3. CLAUDE.md (global) — NOT copied, manually maintained

| Location | |
|---|---|
| `~/.claude/CLAUDE.md` | **DO NOT overwrite from repo** |

**What it does:** Global Claude Code instructions. References SKILL.md and
REPORT_RULES.md. Contains port selection rules and mandatory analysis rules.

**Verify after pull** (manual check, don't copy):
- Rule #6 references `~/.claude/REPORT_RULES.md`
- Port selection table matches current architecture
- Path parameter warning is present

---

## Docker Files (priv/)

These files are bundled into the Docker image and served via API endpoints.

| Source (repo) | Destination (priv) | Served at |
|---|---|---|
| `REPORT_RULES.md` | `priv/REPORT_RULES.md` | `GET /api/intelligence/report_rules` |

After updating `priv/` files, rebuild Docker to include them in the image:

```bash
docker compose build
docker compose up -d
```

---

## Verification Commands

After distributing all files, verify:

```bash
# 1. Global files exist
ls -la ~/.claude/SKILL.md ~/.claude/REPORT_RULES.md ~/.claude/CLAUDE.md

# 2. priv/ files exist
ls -la priv/REPORT_RULES.md

# 3. API endpoint serves rules (after Docker rebuild)
curl -s http://localhost:4000/api/intelligence/report_rules | head -5

# 4. Diff check — ensure global copies match repo source
diff SKILL.md ~/.claude/SKILL.md
diff REPORT_RULES.md ~/.claude/REPORT_RULES.md
diff REPORT_RULES.md priv/REPORT_RULES.md
```

If any diff shows changes, re-copy from repo source (repo is always the source of truth).

---

## Git Hook Setup (One-Time Per Machine)

The `.git/hooks/` directory is local and not tracked by git. On each new machine
(or fresh clone), set up a `post-merge` hook to automate file distribution.

**Check if hook exists:**

```bash
ls -la .git/hooks/post-merge
```

**If missing, create it:**

```bash
cat > .git/hooks/post-merge << 'HOOK'
#!/bin/bash
# AFTER_PULL automation — distributes system-wide files after git pull

echo "=== Giulia post-merge hook ==="

# SKILL.md → global Claude config
if [ -f "SKILL.md" ]; then
  cp SKILL.md ~/.claude/SKILL.md
  echo "[OK] SKILL.md → ~/.claude/SKILL.md"
fi

# REPORT_RULES.md → global Claude config + priv/
if [ -f "REPORT_RULES.md" ]; then
  cp REPORT_RULES.md ~/.claude/REPORT_RULES.md
  cp REPORT_RULES.md priv/REPORT_RULES.md
  echo "[OK] REPORT_RULES.md → ~/.claude/ + priv/"
fi

# Diff check — warn if global CLAUDE.md might need manual update
if [ -f ~/.claude/CLAUDE.md ]; then
  echo "[INFO] ~/.claude/CLAUDE.md exists (manual maintenance — check AFTER_PULL.md)"
else
  echo "[WARN] ~/.claude/CLAUDE.md is missing — create it manually (see AFTER_PULL.md)"
fi

echo "=== Done. Review AFTER_PULL.md for manual checks. ==="
HOOK
chmod +x .git/hooks/post-merge
echo "Hook created."
```

**Also cover `git pull --rebase` (post-rewrite delegates to post-merge):**

```bash
cat > .git/hooks/post-rewrite << 'HOOK'
#!/bin/bash
[ "$1" = "rebase" ] || exit 0
exec "$(dirname "$0")/post-merge"
HOOK
chmod +x .git/hooks/post-rewrite
```

**Verify hook works:**

```bash
# Simulate a pull (runs the hook manually)
.git/hooks/post-merge
```

After setup, every `git pull` on this repo will automatically distribute
files. The manual checklist above remains the reference for what and why —
the hook just automates the copy steps.

---

## When to Run This Checklist

- **First clone on a new machine** — run everything manually, then set up the hook
- After every `git pull` if the hook is NOT installed
- After modifying SKILL.md, REPORT_RULES.md, or global CLAUDE.md rules
- Before rebuilding Docker images (ensure priv/ is current)
- After adding new system-wide files (update this checklist AND the hook)
