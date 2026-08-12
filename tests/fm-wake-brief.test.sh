#!/usr/bin/env bash
# tests/fm-wake-brief.test.sh - the one-read wake brief (bin/fm-wake-brief.sh)
# and its wiring into bin/fm-wake-drain.sh.
#
# The contract under test is "acting on a wake costs ONE read": every brief line
# must already carry the task, its current state, its last status line, and a
# single concrete next action, so the supervisor never has to open the status
# file, the meta, or the fleet view just to decide what to do. These tests assert
# that shape per wake kind and per crew state, and that the drain still prints
# the durable records unchanged above the brief - the records are the lossless
# log and existing consumers keep parsing them.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

BRIEF="$ROOT/bin/fm-wake-brief.sh"
DRAIN="$ROOT/bin/fm-wake-drain.sh"

TMP_ROOT=$(fm_test_tmproot fm-wake-brief-tests)
STATE="$TMP_ROOT/state"
FAKEBIN="$TMP_ROOT/fakebin"
mkdir -p "$STATE" "$FAKEBIN"
make_fake_crew_state "$FAKEBIN" >/dev/null

# Render records through the brief with the hermetic crew-state fake.
brief() {  # <records...>  (each already TAB-separated)
  local rec
  for rec in "$@"; do printf '%s\n' "$rec"; done \
    | FM_STATE_OVERRIDE="$STATE" FM_CREW_STATE_BIN="$FAKEBIN/fm-crew-state.sh" "$BRIEF"
}

rec() {  # <kind> <key> [payload]
  printf '1000\t1\t%s\t%s\t%s' "$1" "$2" "${3:-}"
}

# Every brief line must be self-sufficient: one line, and all four fields present.
assert_one_read() {  # <line> <label>
  local line=$1 label=$2
  [ "$(printf '%s\n' "$line" | grep -c .)" = 1 ] || fail "$label: brief was not a single line: $line"
  case "$line" in *"next: "*) ;; *) fail "$label: brief line carries no next action: $line" ;; esac
}

reset_state() {
  rm -f "$STATE"/*.meta "$STATE"/*.status "$STATE"/.wake-queue "$STATE"/.wake-queue.seq 2>/dev/null || true
}

# --- a green PR awaiting merge: the brief names the PR and the merge command ---

reset_state
fm_write_meta "$STATE/ship-a1.meta" "window=test:fm-ship-a1" "kind=ship" "mode=no-mistakes" \
  "harness=claude" "pr=https://example.test/owner/repo/pull/42"
printf 'done: PR https://example.test/owner/repo/pull/42 checks green\n' > "$STATE/ship-a1.status"
export FM_FAKE_CREW_STATE='state: done · source: run-step · checks green: PR ready for review'
LINE=$(brief "$(rec signal ship-a1.status 'signal: ...')")
assert_one_read "$LINE" "green PR"
case "$LINE" in *"ship-a1"*) ;; *) fail "brief did not name the task: $LINE" ;; esac
case "$LINE" in *"state done"*) ;; *) fail "brief did not carry the current state: $LINE" ;; esac
case "$LINE" in *"checks green: PR ready for review"*) ;; *) fail "brief dropped the crew-state detail: $LINE" ;; esac
case "$LINE" in *"last: done: PR https://example.test/owner/repo/pull/42 checks green"*) ;;
  *) fail "brief did not carry the last status line: $LINE" ;; esac
case "$LINE" in *"fm-pr-merge.sh ship-a1 https://example.test/owner/repo/pull/42"*) ;;
  *) fail "brief did not name the merge command with the recorded PR: $LINE" ;; esac
pass "a done crew with a recorded PR briefs its state, its status line, and the exact merge command in one line"

# --- an open decision outranks everything else: answer it ---------------------

reset_state
fm_write_meta "$STATE/ship-b2.meta" "window=test:fm-ship-b2" "kind=ship" "mode=no-mistakes"
printf 'working: setup\nneeds-decision [key=api]: pick A or B\n' > "$STATE/ship-b2.status"
FM_FAKE_CREW_STATE='state: parked · source: run-step · parked at review: 2 finding(s) (ask-user: captain decision)'
LINE=$(brief "$(rec signal ship-b2.status)")
assert_one_read "$LINE" "open decision"
case "$LINE" in *"answer 1 open decision"*) ;; *) fail "brief did not report the open decision: $LINE" ;; esac
case "$LINE" in *"fm-send.sh ship-b2"*) ;; *) fail "brief did not name the reply command: $LINE" ;; esac
case "$LINE" in *"[api] pick A or B"*) ;; *) fail "brief did not carry the decision being asked: $LINE" ;; esac
# An unanswered decision outranks a wake payload that already carries its own
# verdict - the unanswered crew is what is blocking progress, and a declared wait
# on that pane is usually a consequence of it.
LINE=$(brief "$(rec stale test:fm-ship-b2 'stale: x (paused 3700s, awaiting external - declared pause ...)')")
case "$LINE" in *"open decision"*) ;; *) fail "a declared-wait payload masked an unanswered decision: $LINE" ;; esac
pass "an open keyed decision briefs as one answerable decision with the command that answers it, outranking a declared-wait payload"

# A resolved decision must NOT keep briefing as open (the durable fold, not the
# last line, is what decides).
printf 'resolved [key=api]: went with A\n' >> "$STATE/ship-b2.status"
FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)'
LINE=$(brief "$(rec signal ship-b2.status)")
case "$LINE" in *"open decision"*) fail "a resolved decision still briefed as open: $LINE" ;; esac
case "$LINE" in *"no action"*) ;; *) fail "a resumed crew should brief as needing no action: $LINE" ;; esac
pass "a resolved decision drops out of the brief and the resumed crew briefs as no-action"

# --- scout, local-only, and torn-down tasks each get their own next action -----

reset_state
fm_write_meta "$STATE/scout-c3.meta" "window=test:fm-scout-c3" "kind=scout"
printf 'done: root cause found\n' > "$STATE/scout-c3.status"
FM_FAKE_CREW_STATE='state: done · source: status-log · root cause found'
LINE=$(brief "$(rec signal scout-c3.status)")
case "$LINE" in *"data/scout-c3/report.md"*) ;; *) fail "a done scout must brief its report path: $LINE" ;; esac
pass "a done scout briefs its report path, not a PR"

reset_state
fm_write_meta "$STATE/local-d4.meta" "window=test:fm-local-d4" "kind=ship" "mode=local-only"
printf 'done: ready in branch fm/local-d4\n' > "$STATE/local-d4.status"
FM_FAKE_CREW_STATE='state: done · source: status-log · ready in branch fm/local-d4'
LINE=$(brief "$(rec signal local-d4.status)")
case "$LINE" in *"fm-review-diff.sh local-d4"*) ;; *) fail "a local-only done must brief the review command: $LINE" ;; esac
case "$LINE" in *"fm-merge-local.sh local-d4"*) ;; *) fail "a local-only done must brief the merge command: $LINE" ;; esac
pass "a done local-only crew briefs review-then-merge rather than a PR"

reset_state
LINE=$(brief "$(rec stale test:fm-gone)")
case "$LINE" in *"torn down"*) ;; *) fail "a wake for a task with no meta must say so: $LINE" ;; esac
pass "a wake whose task has no metadata briefs as torn down instead of sending the reader hunting"

# --- stale wake payloads that already carry their own verdict -----------------

reset_state
fm_write_meta "$STATE/held-e5.meta" "window=test:fm-held-e5" "kind=ship"
printf 'paused: awaiting the upstream release\n' > "$STATE/held-e5.status"
FM_FAKE_CREW_STATE='state: paused · source: status-log · awaiting the upstream release'
LINE=$(brief "$(rec stale test:fm-held-e5 'stale: test:fm-held-e5 (paused 3700s, awaiting external - declared pause, rechecked on a long cadence not a wedge; confirm the wait still holds)')")
case "$LINE" in *"held-e5"*) ;; *) fail "the stale window did not resolve to its task: $LINE" ;; esac
case "$LINE" in *"confirm the wait still holds"*) ;; *) fail "a declared-wait recheck must brief as a confirmation, not work: $LINE" ;; esac
pass "a declared-wait recheck resolves its window to the task and briefs as a confirmation"

LINE=$(brief "$(rec stale test:fm-held-e5 'stale: test:fm-held-e5 (idle 500s, possible wedge, escalation 3, demand-deep-inspection: ...)')")
case "$LINE" in *"deep inspection demanded"*) ;; *) fail "a demand-deep-inspection wake must brief the deeper reads: $LINE" ;; esac
case "$LINE" in *"fm-crew-state.sh held-e5"*) ;; *) fail "the deep-inspection brief must name the deeper tool: $LINE" ;; esac
pass "a demand-deep-inspection wake briefs the deeper reads instead of a routine resume"

# A per-task check firing is what the check was armed to catch; for the merge
# poll the next lifecycle step is teardown, not another look at the crew.
reset_state
fm_write_meta "$STATE/merged-h9.meta" "window=test:fm-merged-h9" "kind=ship" \
  "pr=https://example.test/o/r/pull/3"
printf 'done: PR https://example.test/o/r/pull/3 checks green\n' > "$STATE/merged-h9.status"
FM_FAKE_CREW_STATE='state: done · source: run-step · run passed: PR merged/closed'
LINE=$(brief "$(rec check "$STATE/merged-h9.check.sh" 'check: /x/merged-h9.check.sh: PR merged')")
case "$LINE" in *"fm-teardown.sh merged-h9"*) ;; *) fail "a fired merge poll must brief teardown: $LINE" ;; esac
# The same word in a non-check payload must not hijack the line.
LINE=$(brief "$(rec signal merged-h9.status 'signal: merged something')")
case "$LINE" in *"fm-teardown.sh"*) fail "a non-check payload hijacked the merge branch: $LINE" ;; esac
pass "a fired merge poll briefs teardown, and only a check wake can take that branch"

reset_state
LINE=$(brief "$(rec heartbeat heartbeat heartbeat)")
case "$LINE" in *"fm-fleet-view.sh"*) ;; *) fail "a heartbeat must brief the fleet review: $LINE" ;; esac
pass "a heartbeat briefs the fleet review it calls for"

# --- one crew-state read per distinct task across a coalesced batch -----------

reset_state
fm_write_meta "$STATE/batch-f6.meta" "window=test:fm-batch-f6" "kind=ship"
printf 'working: compiling\n' > "$STATE/batch-f6.status"
COUNTER="$TMP_ROOT/cs-calls"
: > "$COUNTER"
cat > "$FAKEBIN/counting-crew-state.sh" <<'SH'
#!/usr/bin/env bash
printf 'x\n' >> "$FM_TEST_CS_COUNTER"
printf 'state: working · source: run-step · validating (running)\n'
SH
chmod +x "$FAKEBIN/counting-crew-state.sh"
OUT=$(printf '%s\n%s\n' "$(rec signal batch-f6.status)" "$(rec signal batch-f6.turn-ended)" \
  | FM_STATE_OVERRIDE="$STATE" FM_TEST_CS_COUNTER="$COUNTER" \
    FM_CREW_STATE_BIN="$FAKEBIN/counting-crew-state.sh" "$BRIEF")
[ "$(printf '%s\n' "$OUT" | grep -c .)" = 2 ] || fail "a two-record batch must brief two lines: $OUT"
[ "$(grep -c . "$COUNTER")" = 1 ] || fail "the same task must cost ONE crew-state read per batch, got $(grep -c . "$COUNTER")"
pass "a coalesced batch naming one task twice costs a single crew-state read"

# --- drain wiring: records unchanged, brief appended, opt-out honored ---------

reset_state
fm_write_meta "$STATE/drain-g7.meta" "window=test:fm-drain-g7" "kind=ship" \
  "pr=https://example.test/owner/repo/pull/7"
printf 'done: PR https://example.test/owner/repo/pull/7 checks green\n' > "$STATE/drain-g7.status"
append_wake "$STATE" signal drain-g7.status "signal: $STATE/drain-g7.status"
OUT=$(FM_STATE_OVERRIDE="$STATE" FM_CREW_STATE_BIN="$FAKEBIN/fm-crew-state.sh" \
  FM_FAKE_CREW_STATE='state: done · source: run-step · checks green: PR ready for review' \
  "$DRAIN" 2>/dev/null)
printf '%s' "$OUT" | grep "$(printf '\tsignal\t')" >/dev/null \
  || fail "the drain must still print the durable records unchanged: $OUT"
printf '%s' "$OUT" | grep -F -- '--- wake brief' >/dev/null || fail "the drain did not print the wake brief block: $OUT"
printf '%s' "$OUT" | grep -F 'fm-pr-merge.sh drain-g7' >/dev/null || fail "the drain's brief carried no next action: $OUT"

append_wake "$STATE" signal drain-g7.status "signal: $STATE/drain-g7.status"
OUT=$(FM_STATE_OVERRIDE="$STATE" FM_WAKE_BRIEF=0 "$DRAIN" 2>/dev/null)
printf '%s' "$OUT" | grep "$(printf '\tsignal\t')" >/dev/null || fail "FM_WAKE_BRIEF=0 must still print records: $OUT"
printf '%s' "$OUT" | grep -F -- '--- wake brief' >/dev/null && fail "FM_WAKE_BRIEF=0 must suppress the brief: $OUT"
pass "the drain prints durable records unchanged, appends the brief, and honors FM_WAKE_BRIEF=0"

# An empty queue drains silently, brief and all - a quiet drain stays quiet.
OUT=$(FM_STATE_OVERRIDE="$STATE" "$DRAIN" 2>/dev/null)
[ -z "$OUT" ] || fail "an empty drain must print nothing at all, got: $OUT"
pass "an empty drain stays silent"

unset FM_FAKE_CREW_STATE
printf '# %s: all assertions passed\n' "$(basename "$0")"
