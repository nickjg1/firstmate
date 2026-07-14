#!/usr/bin/env bash
# Behavior tests for the worktree-tangle guards.
#
# Firstmate is a treehouse-pooled git repo of itself: linked worktrees and
# secondmate homes all sit at a detached HEAD on the default branch, while the
# PRIMARY checkout (FM_ROOT) is a normal checkout on a real branch. The "tangle"
# is a crewmate branching/committing in the primary instead of its own worktree,
# stranding the primary on a feature branch. Two guards cover it:
#   GUARD 1 (prevention) - the brief asserts isolation before its branch step, and
#            fm-spawn refuses to launch unless the resolved worktree is isolated.
#   GUARD 2 (detection)  - fm-guard and fm-bootstrap alarm when the primary is on
#            a feature branch, and stay silent on the default branch or detached.
# These cases pin: the shared lib's branch classification, the fm-guard banner,
# the fm-bootstrap problem line, the brief assertion ordering, and the fm-spawn
# abort - all hermetic over temp git repos and fakebins.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=bin/fm-tangle-lib.sh
. "$ROOT/bin/fm-tangle-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-tangle-guard)
fm_git_identity fmtest fmtest@example.invalid

# A fresh git repo on `main` with one commit. Echoes its path.
make_repo() {
  local dir=$1
  git init -q -b main "$dir"
  git -C "$dir" commit -q --allow-empty -m init
  printf '%s\n' "$dir"
}

# --- shared lib: branch classification --------------------------------------

# fm_primary_tangle_branch is the whole scoping decision: a NAMED non-default
# branch is the tangle; the default branch and detached HEAD are healthy.
test_lib_classification() {
  local repo n=0 label state branch expect out
  repo=$(make_repo "$TMP_ROOT/lib-repo")
  while IFS='|' read -r label state branch expect; do
    [ -n "$label" ] || continue
    n=$((n + 1))
    case "$state" in
      default)  git -C "$repo" checkout -q main ;;
      feature)  git -C "$repo" checkout -q -B "$branch" ;;
      detached) git -C "$repo" checkout -q main; git -C "$repo" checkout -q --detach ;;
    esac
    out=$(fm_primary_tangle_branch "$repo" || true)
    [ "$out" = "$expect" ] || fail "$label: expected tangle='$expect', got '$out'"
  done <<'ROWS'
on the default branch is healthy|default||
on a feature branch is the tangle|feature|fm/readme-restructure-d3|fm/readme-restructure-d3
detached HEAD on default is healthy (worktrees, secondmate homes)|detached||
ROWS
  # A non-git directory is not a tangle and must not error.
  out=$(fm_primary_tangle_branch "$TMP_ROOT" || true)
  [ -z "$out" ] || fail "non-git dir wrongly reported a tangle: '$out'"
  pass "fm_primary_tangle_branch: feature branch alarms; default/detached/non-git stay silent"
}

# --- GUARD 2a: fm-guard banner ----------------------------------------------

run_guard() {
  # Scope the guard to a temp repo as the primary checkout; state lives under it.
  FM_ROOT_OVERRIDE="$1" FM_HOME="$1" "$ROOT/bin/fm-guard.sh" 2>&1
}

test_guard_banner() {
  local repo out
  repo=$(make_repo "$TMP_ROOT/guard-repo")

  out=$(run_guard "$repo")
  assert_not_contains "$out" "WORKTREE TANGLE" "guard alarmed while primary was on main"

  git -C "$repo" checkout -q --detach
  out=$(run_guard "$repo")
  assert_not_contains "$out" "WORKTREE TANGLE" "guard alarmed on a detached HEAD (legitimate worktree state)"

  git -C "$repo" checkout -q -B fm/tangle-aa1
  out=$(run_guard "$repo")
  assert_contains "$out" "WORKTREE TANGLE" "guard did not alarm on a feature branch in the primary"
  assert_contains "$out" "fm/tangle-aa1" "guard banner did not name the offending branch"
  assert_contains "$out" "checkout main" "guard banner did not print the restore remediation"
  out=$(FM_GUARD_READ_ONLY=1 run_guard "$repo")
  assert_contains "$out" "WORKTREE TANGLE" "read-only guard did not keep the tangle alarm"
  assert_contains "$out" "read-only session must leave restore work" "read-only guard did not explain restore ownership"
  assert_not_contains "$out" "checkout main" "read-only guard printed a state-changing restore command"
  pass "fm-guard: bordered tangle banner fires only for a feature branch and suppresses repair commands in read-only mode"
}

# --- GUARD 2b: fm-bootstrap problem line ------------------------------------

run_bootstrap() {
  # No projects/ under the home keeps fleet sync inert; grep isolates the line.
  FM_ROOT_OVERRIDE="$1" FM_HOME="$1" "$ROOT/bin/fm-bootstrap.sh" 2>/dev/null
}

test_bootstrap_line() {
  local repo out
  repo=$(make_repo "$TMP_ROOT/bootstrap-repo")

  out=$(run_bootstrap "$repo" | grep '^TANGLE:' || true)
  [ -z "$out" ] || fail "bootstrap emitted a TANGLE line while on main: $out"

  git -C "$repo" checkout -q --detach
  out=$(run_bootstrap "$repo" | grep '^TANGLE:' || true)
  [ -z "$out" ] || fail "bootstrap emitted a TANGLE line on a detached HEAD: $out"

  git -C "$repo" checkout -q -B fm/tangle-bb2
  out=$(run_bootstrap "$repo" | grep '^TANGLE:' || true)
  assert_contains "$out" "fm/tangle-bb2" "bootstrap did not report the tangled branch"
  assert_contains "$out" "checkout main" "bootstrap TANGLE line lacked the restore remediation"
  out=$(FM_ROOT_OVERRIDE="$repo" FM_HOME="$repo" FM_BOOTSTRAP_DETECT_ONLY=1 "$ROOT/bin/fm-bootstrap.sh" 2>/dev/null | grep '^TANGLE:' || true)
  assert_contains "$out" "fm/tangle-bb2" "detect-only bootstrap did not report the tangled branch"
  assert_contains "$out" "read-only session must leave restore work" "detect-only bootstrap did not explain restore ownership"
  assert_not_contains "$out" "checkout main" "detect-only bootstrap printed a state-changing restore command"
  pass "fm-bootstrap: TANGLE problem line fires only for a feature branch and suppresses repair commands in detect-only mode"
}

# --- GUARD 1a: brief isolation assertion ------------------------------------

# The generated ship brief must carry the isolation assertion AHEAD of the
# `git checkout -b` step, so the crewmate verifies its worktree before branching.
test_brief_assertion_precedes_branch() {
  local home brief iso br
  home="$TMP_ROOT/brief-home"
  mkdir -p "$home/data"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" tangle-brief-cc3 alpha >/dev/null 2>&1
  brief="$home/data/tangle-brief-cc3/brief.md"
  assert_present "$brief" "brief was not scaffolded"
  assert_grep "blocked: launched in primary checkout, not an isolated worktree" "$brief" \
    "brief is missing the isolation blocked-status contract"
  assert_grep "The path check is authoritative" "$brief" \
    "brief must make the path check authoritative"
  assert_no_grep "A reliable test that you are in a linked worktree" "$brief" \
    "brief must not present git-dir/common-dir as decisive"
  assert_no_grep "they are identical in the primary checkout" "$brief" \
    "brief must not claim the primary checkout has identical git dirs"
  iso=$(grep -n 'launched in primary checkout, not an isolated worktree' "$brief" | head -1 | cut -d: -f1)
  br=$(grep -n 'git checkout -b fm/' "$brief" | head -1 | cut -d: -f1)
  if [ -z "$iso" ] || [ -z "$br" ]; then
    fail "brief missing assertion ($iso) or branch step ($br)"
  fi
  [ "$iso" -lt "$br" ] || fail "isolation assertion (line $iso) must precede the branch step (line $br)"
  pass "fm-brief: ship brief asserts worktree isolation before the branch step"
}

# --- GUARD 1b: fm-spawn isolation abort -------------------------------------

# A fake tmux that reports FM_FAKE_PANE_PATH as the post-`treehouse get` pane cwd
# (so the spawn's worktree-resolution loop resolves to a path we control), names
# the session on '#S', and swallows window ops. When FM_FAKE_PANE_SEQ names a
# file, each pane-cwd query instead pops the next line from it (repeating the
# last line once exhausted), so a test can make the pane path CHANGE between the
# detection poll and the pre-record cross-check. Echoes the fakebin dir.
make_spawn_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*)
    if [ -n "${FM_FAKE_PANE_SEQ:-}" ] && [ -f "$FM_FAKE_PANE_SEQ" ]; then
      n=$(cat "$FM_FAKE_PANE_SEQ.n" 2>/dev/null || echo 0)
      n=$((n + 1))
      printf '%s\n' "$n" > "$FM_FAKE_PANE_SEQ.n"
      total=$(grep -c '' "$FM_FAKE_PANE_SEQ")
      [ "$n" -le "$total" ] || n=$total
      sed -n "${n}p" "$FM_FAKE_PANE_SEQ"
    else
      printf '%s\n' "${FM_FAKE_PANE_PATH:-}"
    fi
    exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|new-window|send-keys) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse
  printf '%s\n' "$fakebin"
}

run_spawn() {
  local home=$1 id=$2 proj=$3 pane=$4 fakebin=$5 harness=${6:-codex}
  mkdir -p "$home/data/$id"
  printf 'brief\n' > "$home/data/$id/brief.md"
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$pane" TMUX="fake,1,0" \
    FM_SPAWN_WORKTREE_POLL_SECS="${FM_SPAWN_WORKTREE_POLL_SECS:-2}" \
    PATH="$fakebin:$PATH" \
    "$ROOT/bin/fm-spawn.sh" "$id" "$proj" "$harness" 2>&1
}

test_spawn_isolation_abort() {
  local home proj fakebin out status
  home="$TMP_ROOT/spawn-home"
  mkdir -p "$home/data"
  proj=$(make_repo "$TMP_ROOT/spawn-proj")
  fakebin=$(make_spawn_fakebin "$TMP_ROOT/spawn-fake")
  # A genuine isolated linked worktree of the project, detached on the default.
  git -C "$proj" worktree add -q --detach "$TMP_ROOT/spawn-wt" >/dev/null 2>&1
  mkdir -p "$TMP_ROOT/spawn-notgit" "$proj/sub"

  # Abort: the pane resolves to a plain non-git directory (not a worktree at all).
  # The worktree-detection poll only accepts a genuine linked worktree of the
  # project, so a non-worktree pane is never recorded; the bounded poll times out.
  out=$(run_spawn "$home" abort-notgit-dd4 "$proj" "$TMP_ROOT/spawn-notgit" "$fakebin"); status=$?
  expect_code 1 "$status" "spawn into a non-worktree dir should abort"
  assert_contains "$out" "did not enter the project's worktree" "non-worktree spawn was not rejected by the poll"
  assert_absent "$home/state/abort-notgit-dd4.meta" "aborted spawn must not record meta"

  # Abort: the pane resolves INTO the primary checkout (a subdir of PROJ_ABS). It
  # shares the project's git-common-dir but its toplevel is the primary, so the
  # poll rejects it (the tangle case) rather than recording it.
  out=$(run_spawn "$home" abort-primary-ee5 "$proj" "$proj/sub" "$fakebin"); status=$?
  expect_code 1 "$status" "spawn landing inside the primary checkout should abort"
  assert_contains "$out" "did not enter the project's worktree" "primary-checkout spawn was not rejected by the poll"
  assert_absent "$home/state/abort-primary-ee5.meta" "aborted spawn must not record meta"

  # Proceed: the pane resolves to a genuine, isolated worktree.
  out=$(run_spawn "$home" ok-isolated-ff6 "$proj" "$TMP_ROOT/spawn-wt" "$fakebin"); status=$?
  expect_code 0 "$status" "spawn into a genuine isolated worktree should succeed"
  assert_contains "$out" "spawned ok-isolated-ff6" "isolated spawn did not report success"
  assert_grep "worktree=$TMP_ROOT/spawn-wt" "$home/state/ok-isolated-ff6.meta" "isolated spawn recorded the wrong worktree="
  pass "fm-spawn: records only a genuine isolated worktree and aborts on any non-worktree pane"
}

# The pre-record cross-check re-reads the live pane cwd against the detected
# worktree before writing the meta. A pane that PERSISTENTLY diverges after
# detection must abort without stranding any task state (meta, turn-end token,
# task tmp); a TRANSIENT rc-driven cd into a non-worktree dir (the oh-my-zsh
# case) between detection and the cross-check must be absorbed by the full poll
# budget; a pane sitting in a DIFFERENT leased worktree of the project is a
# genuine misdetection and must abort fast, without burning that budget.
test_spawn_cross_check_divergence() {
  local home proj fakebin seq out status
  home="$TMP_ROOT/cross-home"
  mkdir -p "$home/data"
  proj=$(make_repo "$TMP_ROOT/cross-proj")
  fakebin=$(make_spawn_fakebin "$TMP_ROOT/cross-fake")
  git -C "$proj" worktree add -q --detach "$TMP_ROOT/cross-wt" >/dev/null 2>&1
  make_repo "$TMP_ROOT/cross-omz" >/dev/null

  # Persistent divergence: detection sees the real worktree, every later sample
  # sees an unrelated repo. The spawn must abort and leave no task artifacts.
  seq="$TMP_ROOT/cross-seq-persist"
  printf '%s\n%s\n' "$TMP_ROOT/cross-wt" "$TMP_ROOT/cross-omz" > "$seq"
  out=$(FM_FAKE_PANE_SEQ="$seq" run_spawn "$home" cross-diverge-hh7 "$proj" "$TMP_ROOT/cross-wt" "$fakebin"); status=$?
  expect_code 1 "$status" "a persistently diverged pane must abort the spawn"
  assert_contains "$out" "does not match the live pane cwd" "diverged spawn lacked the cross-check error"
  assert_absent "$home/state/cross-diverge-hh7.meta" "aborted spawn must not record meta"
  assert_absent "$home/state/cross-diverge-hh7.grok-turnend-token" "aborted spawn must not leave a turn-end token"
  [ ! -d "/tmp/fm-cross-diverge-hh7" ] || fail "aborted spawn must remove its task tmp dir"

  # Transient divergence: one contaminated sample between detection and the
  # cross-check, then the pane is back in the worktree. The retry must absorb it.
  seq="$TMP_ROOT/cross-seq-transient"
  printf '%s\n%s\n%s\n' "$TMP_ROOT/cross-wt" "$TMP_ROOT/cross-omz" "$TMP_ROOT/cross-wt" > "$seq"
  out=$(FM_FAKE_PANE_SEQ="$seq" run_spawn "$home" cross-transient-jj8 "$proj" "$TMP_ROOT/cross-wt" "$fakebin"); status=$?
  expect_code 0 "$status" "a transient rc-driven cd must not abort the spawn"
  assert_contains "$out" "spawned cross-transient-jj8" "transient-divergence spawn did not report success"
  assert_grep "worktree=$TMP_ROOT/cross-wt" "$home/state/cross-transient-jj8.meta" "transient-divergence spawn recorded the wrong worktree="

  # Misdetection: after detection the pane sits in a DIFFERENT leased worktree
  # of the project. This must abort on the first sample; a regression that sent
  # it through the transient poll instead would burn the 15s budget below and
  # then emit the timeout message, failing the message assertion.
  git -C "$proj" worktree add -q --detach "$TMP_ROOT/cross-wt2" >/dev/null 2>&1
  seq="$TMP_ROOT/cross-seq-otherwt"
  printf '%s\n%s\n' "$TMP_ROOT/cross-wt" "$TMP_ROOT/cross-wt2" > "$seq"
  out=$(FM_SPAWN_WORKTREE_POLL_SECS=15 FM_FAKE_PANE_SEQ="$seq" run_spawn "$home" cross-otherwt-kk9 "$proj" "$TMP_ROOT/cross-wt" "$fakebin"); status=$?
  expect_code 1 "$status" "a pane in a different leased worktree must abort the spawn"
  assert_contains "$out" "different leased worktree" "misdetection abort lacked the different-worktree error"
  assert_absent "$home/state/cross-otherwt-kk9.meta" "aborted spawn must not record meta"
  [ ! -d "/tmp/fm-cross-otherwt-kk9" ] || fail "aborted spawn must remove its task tmp dir"
  pass "fm-spawn: cross-check aborts cleanly on persistent divergence, absorbs a transient one, and fails fast on a different worktree"
}

# The cross-check abort must remove every per-harness artifact the spawn wrote
# just before it (grok: state token, global-hook auth file, worktree token
# pointer; pi: the state extension; claude: the worktree-resident Stop hook),
# because an aborted spawn writes no meta and never gets a teardown.
test_spawn_cross_check_abort_cleanup() {
  local home proj fakebin seq grokhome out status auth_leftover
  home="$TMP_ROOT/clean-home"
  mkdir -p "$home/data"
  proj=$(make_repo "$TMP_ROOT/clean-proj")
  fakebin=$(make_spawn_fakebin "$TMP_ROOT/clean-fake")
  git -C "$proj" worktree add -q --detach "$TMP_ROOT/clean-wt" >/dev/null 2>&1
  make_repo "$TMP_ROOT/clean-omz" >/dev/null
  grokhome="$TMP_ROOT/clean-grok-home"

  seq="$TMP_ROOT/clean-seq-grok"
  printf '%s\n%s\n' "$TMP_ROOT/clean-wt" "$TMP_ROOT/clean-omz" > "$seq"
  out=$(GROK_HOME="$grokhome" FM_FAKE_PANE_SEQ="$seq" run_spawn "$home" clean-grok-mm1 "$proj" "$TMP_ROOT/clean-wt" "$fakebin" grok); status=$?
  expect_code 1 "$status" "grok persistent divergence must abort the spawn"
  assert_contains "$out" "does not match the live pane cwd" "grok abort lacked the cross-check error"
  assert_absent "$home/state/clean-grok-mm1.meta" "aborted grok spawn must not record meta"
  assert_absent "$home/state/clean-grok-mm1.grok-turnend-token" "aborted grok spawn must not leave the state token"
  assert_absent "$TMP_ROOT/clean-wt/.fm-grok-turnend" "aborted grok spawn must not leave the worktree token pointer"
  auth_leftover=$(find "$grokhome/hooks/fm-turn-end.d" -type f 2>/dev/null || true)
  [ -z "$auth_leftover" ] || fail "aborted grok spawn must remove its global-hook auth file"
  [ ! -d "/tmp/fm-clean-grok-mm1" ] || fail "aborted grok spawn must remove its task tmp dir"

  seq="$TMP_ROOT/clean-seq-pi"
  printf '%s\n%s\n' "$TMP_ROOT/clean-wt" "$TMP_ROOT/clean-omz" > "$seq"
  out=$(FM_FAKE_PANE_SEQ="$seq" run_spawn "$home" clean-pi-mm2 "$proj" "$TMP_ROOT/clean-wt" "$fakebin" pi); status=$?
  expect_code 1 "$status" "pi persistent divergence must abort the spawn"
  assert_contains "$out" "does not match the live pane cwd" "pi abort lacked the cross-check error"
  assert_absent "$home/state/clean-pi-mm2.meta" "aborted pi spawn must not record meta"
  assert_absent "$home/state/clean-pi-mm2.pi-ext.ts" "aborted pi spawn must not leave the pi extension"

  seq="$TMP_ROOT/clean-seq-claude"
  printf '%s\n%s\n' "$TMP_ROOT/clean-wt" "$TMP_ROOT/clean-omz" > "$seq"
  out=$(FM_FAKE_PANE_SEQ="$seq" run_spawn "$home" clean-claude-mm3 "$proj" "$TMP_ROOT/clean-wt" "$fakebin" claude); status=$?
  expect_code 1 "$status" "claude persistent divergence must abort the spawn"
  assert_contains "$out" "does not match the live pane cwd" "claude abort lacked the cross-check error"
  assert_absent "$home/state/clean-claude-mm3.meta" "aborted claude spawn must not record meta"
  assert_absent "$TMP_ROOT/clean-wt/.claude/settings.local.json" "aborted claude spawn must not leave the worktree Stop hook"

  pass "fm-spawn: cross-check abort removes every per-harness artifact"
}

# --- GUARD 1c: fm-spawn tmux window construction ----------------------------

# The prevention guard also depends on fm-spawn building robust tmux commands
# under a non-default tmux config (base-index 1, automatic-rename on). A RECORDING
# fake tmux logs every invocation and returns a sentinel window id, so these
# assertions pin the command construction deterministically, with no live tmux:
#   - window creation targets the session with a trailing colon (append form), so
#     tmux appends at the next free index instead of the active window index, which
#     collides under base-index 1;
#   - the window id is captured (-P -F #{window_id}) and automatic-rename/allow-rename
#     are disabled so the fm-<id> name survives treehouse cd'ing into the worktree;
#   - the treehouse-get send-keys and the worktree wait loop target that stable
#     window id, never the (possibly-renamed) name - a lost name would let
#     display-message fall back to the active client's window and misread firstmate's
#     OWN pane as the worktree, tangling a hook into the primary checkout.
make_spawn_record_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
[ -n "${FM_TMUX_REC:-}" ] && printf 'tmux %s\n' "$*" >> "$FM_TMUX_REC"
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  new-window) printf '%s\n' "@spawnwid"; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|send-keys|set-window-option) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse
  printf '%s\n' "$fakebin"
}

run_spawn_record() {
  local home=$1 id=$2 proj=$3 pane=$4 fakebin=$5 rec=$6
  mkdir -p "$home/data/$id"
  printf 'brief\n' > "$home/data/$id/brief.md"
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$pane" TMUX="fake,1,0" \
    FM_TMUX_REC="$rec" \
    PATH="$fakebin:$PATH" \
    "$ROOT/bin/fm-spawn.sh" "$id" "$proj" codex 2>&1
}

test_spawn_tmux_window_construction() {
  local home proj fakebin rec wt out status
  home="$TMP_ROOT/spawn-rec-home"
  mkdir -p "$home/data"
  proj=$(make_repo "$TMP_ROOT/spawn-rec-proj")
  fakebin=$(make_spawn_record_fakebin "$TMP_ROOT/spawn-rec-fake")
  rec="$TMP_ROOT/spawn-rec.log"
  : > "$rec"
  wt="$TMP_ROOT/spawn-rec-wt"
  git -C "$proj" worktree add -q --detach "$wt" >/dev/null 2>&1

  out=$(run_spawn_record "$home" rec-win-gg7 "$proj" "$wt" "$fakebin" "$rec"); status=$?
  expect_code 0 "$status" "spawn into a genuine worktree should succeed"
  assert_contains "$out" "spawned rec-win-gg7" "recording spawn did not report success"

  # Bug 1 fix: append-form window creation (trailing colon on the session target).
  assert_grep "new-window -dP -F #{window_id} -t firstmate: -n fm-rec-win-gg7" "$rec" \
    "new-window must append at the session (trailing colon) and capture the window id"
  assert_no_grep "new-window -dP -F #{window_id} -t firstmate -n" "$rec" \
    "new-window must not target the bare session name (collides under base-index 1)"

  # Bug 2 fix (a): pin the window name against automatic-rename / allow-rename.
  assert_grep "set-window-option -t @spawnwid automatic-rename off" "$rec" \
    "must disable automatic-rename on the spawned window"
  assert_grep "set-window-option -t @spawnwid allow-rename off" "$rec" \
    "must disable allow-rename on the spawned window"

  # Bug 2 fix (b): treehouse-get and the worktree wait loop target the stable id.
  assert_grep "send-keys -t @spawnwid treehouse get Enter" "$rec" \
    "treehouse get must be sent to the stable window id"
  assert_grep "display-message -p -t @spawnwid #{pane_current_path}" "$rec" \
    "the worktree wait loop must query the stable window id, not the name"

  pass "fm-spawn: appends windows by session-colon, pins the name, and targets the window id"
}

test_lib_classification
test_guard_banner
test_bootstrap_line
test_brief_assertion_precedes_branch
test_spawn_isolation_abort
test_spawn_cross_check_divergence
test_spawn_cross_check_abort_cleanup
test_spawn_tmux_window_construction
