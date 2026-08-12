#!/usr/bin/env bash
# fm-wake-brief.sh - render drained wake records as ONE compact actionable line
# each, so handling a wake costs a single read instead of several.
#
# Why this exists: the wake records bin/fm-wake-drain.sh prints are a durable
# LOG - kind, key, and the watcher's raw reason - and nothing more. Acting on one
# meant separately reading the task's status file, its meta, sometimes
# bin/fm-crew-state.sh, and sometimes the whole fleet view, every time. Those
# follow-up reads are cheap in seconds and expensive in supervisor tokens, and
# they are the same reads every time, so they belong in bash. This script does
# them once per DISTINCT task in the batch and folds the answer into one line:
#
#   <kind> <task> · <current state> · last: <status line> · next: <action>
#
# The `next:` field is a deterministic lookup, never a judgement call: it names
# the single command or relay the lifecycle already prescribes for that state
# (AGENTS.md sections 7 and 8). It is a starting point, not a licence to skip
# thinking - anything it cannot resolve says so and points at the deeper tool.
#
# The deeper tools are unchanged and still authoritative when a line says to use
# them: bin/fm-crew-state.sh for one crew's live state, bin/fm-peek.sh for a pane,
# bin/fm-fleet-view.sh for the whole fleet, and the status log itself for older
# wake-event history.
#
# Usage:
#   fm-wake-brief.sh [<records-file>]   records default to stdin
# Records are the durable-queue format bin/fm-wake-lib.sh writes and
# bin/fm-wake-drain.sh prints: <epoch>\t<seq>\t<kind>\t<key>\t<payload>.
# Malformed lines are skipped rather than failing the drain.
#
# Env:
#   FM_WAKE_BRIEF_CREW_STATE=0  skip the bin/fm-crew-state.sh read and report
#                               state from the status log alone (cheaper, less
#                               accurate; the log is an event log, not a state).
#   FM_WAKE_BRIEF_MAX=<n>       cap the rendered records (default 50).
# Always exits 0: a brief is an aid to handling wakes and must never fail a drain.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"

CREW_STATE_BIN="${FM_CREW_STATE_BIN:-$SCRIPT_DIR/fm-crew-state.sh}"
READ_CREW_STATE=${FM_WAKE_BRIEF_CREW_STATE:-1}
MAX=${FM_WAKE_BRIEF_MAX:-50}
case "$MAX" in ''|*[!0-9]*) MAX=50 ;; esac
SEP=' · '

case "${1:-}" in
  -h|--help)
    awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
    exit 0
    ;;
esac

meta_field() {  # <task> <key>
  local task=$1 field=$2
  [ -f "$STATE/$task.meta" ] || return 0
  grep "^$field=" "$STATE/$task.meta" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

# Task id a wake record refers to, or empty when the record names no single task
# (a heartbeat, or a check shim that is not per-task such as the X-mode relay).
record_task() {  # <kind> <key>
  local kind=$1 key=$2 base
  base=${key##*/}
  case "$kind" in
    signal)
      case "$base" in
        *.status)     printf '%s' "${base%.status}" ;;
        *.turn-ended) printf '%s' "${base%.turn-ended}" ;;
      esac
      ;;
    stale) window_to_task "$key" "$STATE" ;;
    check)
      case "$base" in
        x-watch.check.sh) ;;
        *.check.sh)       printf '%s' "${base%.check.sh}" ;;
      esac
      ;;
  esac
}

# One crew-state read per distinct task, memoized across the batch so a coalesced
# wake naming a task twice costs one bounded call, not two - the read may shell
# out to no-mistakes, so repeating it is the expensive mistake this whole script
# exists to avoid. The answer is returned in CS_LINE rather than on stdout
# precisely so the memo survives: a command substitution would run the memo write
# in a subshell and discard it.
CS_LINE=""
_cs_memo=""
crew_state_read() {  # <task>
  local task=$1 line
  CS_LINE=""
  [ -n "$task" ] || return 0
  [ "$READ_CREW_STATE" = 0 ] && return 0
  while IFS= read -r line; do
    case "$line" in
      "$task"$'\t'*) CS_LINE=${line#*$'\t'}; return 0 ;;
    esac
  done <<EOF
$_cs_memo
EOF
  line=$("$CREW_STATE_BIN" "$task" 2>/dev/null) || true
  case "$line" in state:*) ;; *) line="" ;; esac
  _cs_memo="${_cs_memo}${task}"$'\t'"${line}"$'\n'
  CS_LINE=$line
}

# "<state>" and a human "<state> (<source>: <detail>)" rendering of a crew-state
# line. With no crew-state read available, fall back to the status log's verb -
# labelled as such, because the log is an EVENT log and may be stale.
# With a crew-state read available its verdict wins outright; without one (the
# FM_WAKE_BRIEF_CREW_STATE=0 path) fall back to the status log's verb through the
# shared mapping, so the rendered state and the chosen next action always agree.
state_of() {  # <crew-state-line> <last-status-line>
  local line=$1 last=${2:-} s
  case "$line" in
    state:*) s=${line#state: }; printf '%s' "${s%%"$SEP"*}"; return ;;
  esac
  [ -n "$last" ] || { printf 'unknown'; return; }
  map_log_state "$last"
}
state_render() {  # <crew-state-line> <last-status-line>
  local line=$1 last=$2 s src detail rest
  if [ -z "$line" ]; then
    if [ -n "$last" ]; then
      printf 'state %s (status-log verb only, may be stale)' "$(status_line_verb "$last")"
    else
      printf 'state unknown (no status, no crew-state read)'
    fi
    return
  fi
  s=${line#state: }; s=${s%%"$SEP"*}
  rest=${line#*source: }
  src=${rest%%"$SEP"*}
  detail=""
  case "$rest" in *"$SEP"*) detail=${rest#*"$SEP"} ;; esac
  if [ -n "$detail" ]; then
    printf 'state %s (%s: %s)' "$s" "$src" "$detail"
  else
    printf 'state %s (%s)' "$s" "$src"
  fi
}

# Flatten the durable open-decision fold into one bounded inline phrase,
# "[<key>] <summary>" joined by "; ", so a brief line carries what is actually
# being asked. Capped at three so one chatty crew cannot swamp a batch.
open_decision_summary() {  # <open-set>
  local open=$1 key note out='' n=0
  # Fields are "<key>\t<verb>\t<summary>"; the verb is discarded because an open
  # decision reads the same whether it was opened by needs-decision or blocked.
  while IFS=$'\t' read -r key _ note; do
    [ -n "$key" ] || continue
    n=$((n + 1))
    if [ "$n" -gt 3 ]; then out="${out}; ..."; break; fi
    [ -n "$out" ] && out="${out}; "
    out="${out}[${key}] ${note}"
  done <<EOF
$open
EOF
  printf '%s' "$out"
}

# The deterministic state -> single-next-action table. Every branch names one
# command or one relay, or says plainly that it cannot tell and points at the
# deeper tool; it never guesses.
next_action() {  # <task> <state> <payload> <open-decisions> <wake-kind>
  local task=$1 state=$2 payload=$3 open=$4 wake=$5 pr kind mode harness window count
  window=$(meta_field "$task" window)
  [ -n "$window" ] || window=$(meta_field "$task" terminal)

  if [ ! -f "$STATE/$task.meta" ]; then
    printf 'no metadata for %s - the task is torn down or never recorded; drop this wake' "$task"
    return
  fi

  # A per-task check firing is a state change the check was armed to catch, and
  # for the common one - the merge poll - the lifecycle's next step is teardown,
  # not another look at the crew. Scoped to check wakes so the word "merged"
  # appearing in some other payload cannot hijack an unrelated line.
  if [ "$wake" = check ]; then
    case "$payload" in
      *merged*|*MERGED*)
        printf 'the armed merge poll fired - confirm the merge, then bin/fm-teardown.sh %s and close the backlog item' "$task"
        return
        ;;
    esac
  fi

  # An unanswered decision outranks every other reading, including a wake whose
  # payload already carries its own verdict: a crew nobody has answered is the
  # thing blocking progress, and a declared wait or a wedge alarm on that pane is
  # usually a consequence of it. Carry the decisions themselves, not just their
  # count - an open decision that is no longer the last status line would
  # otherwise force the very status-file read this brief exists to remove.
  if [ -n "$open" ]; then
    count=$(printf '%s\n' "$open" | grep -c . || true)
    printf 'answer %s open decision(s) with bin/fm-send.sh %s, then expect a resolved: line - %s' \
      "$count" "$task" "$(open_decision_summary "$open")"
    return
  fi

  case "$payload" in
    *demand-deep-inspection*)
      printf 'deep inspection demanded - read bin/fm-crew-state.sh %s, peek %s, and check the validation logs before resuming supervision' "$task" "$window"
      return
      ;;
    *"awaiting external"*)
      printf 'declared external wait, rechecked on a long cadence - confirm the wait still holds, otherwise no action'
      return
      ;;
    *"awaiting merge"*)
      printf 'PR still open and unmerged - confirm it is still wanted, otherwise no action (the merge poll is armed)'
      return
      ;;
  esac

  pr=$(meta_field "$task" pr)
  kind=$(meta_field "$task" kind)
  [ -n "$kind" ] || kind=ship
  mode=$(meta_field "$task" mode)
  harness=$(meta_field "$task" harness)

  case "$state" in
    working)
      printf 'still working - no action; resume supervision'
      ;;
    paused)
      printf 'declared external wait - no action; it rechecks on its own cadence'
      ;;
    parked|blocked)
      printf 'the crew owes an answer - read bin/fm-crew-state.sh %s for the gate, then bin/fm-send.sh %s with the decision' "$task" "$task"
      ;;
    failed)
      printf 'read the evidence in the pane (bin/fm-peek.sh %s) and report the failure with it' "$window"
      ;;
    done)
      if [ "$kind" = scout ]; then
        printf 'read data/%s/report.md, relay the findings, then bin/fm-teardown.sh %s' "$task" "$task"
      elif [ -n "$pr" ]; then
        printf 'PR %s is recorded and the merge poll is armed - relay it, then bin/fm-pr-merge.sh %s %s once approved' "$pr" "$task" "$pr"
      elif [ "$mode" = local-only ]; then
        printf 'review with bin/fm-review-diff.sh %s, relay the summary, then bin/fm-merge-local.sh %s once approved' "$task" "$task"
      elif [ "$mode" = direct-PR ]; then
        printf 'take the PR url from the status line, then bin/fm-pr-check.sh %s <url> and relay it' "$task"
      else
        printf 'trigger the no-mistakes validation in the crew (harness %s), or bin/fm-pr-check.sh %s <url> if it already reported checks green' "${harness:-unknown}" "$task"
      fi
      ;;
    *)
      printf 'state is not readable - peek the pane (bin/fm-peek.sh %s); load stuck-crewmate-recovery if it is wedged' "$window"
      ;;
  esac
}

render_record() {  # <kind> <key> <payload>
  local kind=$1 key=$2 payload=$3 task last cs state open

  if [ "$kind" = heartbeat ]; then
    printf 'heartbeat%sthe fleet scan found a captain-relevant status the per-wake path missed%snext: review the fleet with bin/fm-fleet-view.sh, then act on what it names\n' \
      "$SEP" "$SEP"
    return
  fi

  task=$(record_task "$kind" "$key")
  if [ -z "$task" ]; then
    printf '%s %s%snext: act on the reason as printed above\n' "$kind" "$key" "$SEP"
    return
  fi

  last=$(last_status_line "$STATE/$task.status")
  crew_state_read "$task"
  cs=$CS_LINE
  state=$(state_of "$cs" "$last")
  open=$(status_open_decisions "$STATE/$task.status")

  printf '%s %s%s%s%slast: %s%snext: %s\n' \
    "$kind" "$task" "$SEP" \
    "$(state_render "$cs" "$last")" "$SEP" \
    "${last:--}" "$SEP" \
    "$(next_action "$task" "$state" "$payload" "$open" "$kind")"
}

SRC=${1:-}
n=0
while IFS=$(printf '\t') read -r _epoch _seq kind key payload; do
  [ -n "${kind:-}" ] || continue
  case "$kind" in signal|stale|check|heartbeat) ;; *) continue ;; esac
  n=$((n + 1))
  if [ "$n" -gt "$MAX" ]; then
    printf '... further wake record(s) beyond the first %s are not briefed (FM_WAKE_BRIEF_MAX); read them from the records above\n' \
      "$MAX"
    break
  fi
  render_record "$kind" "${key:-}" "${payload:-}"
done < <(if [ -n "$SRC" ]; then cat "$SRC" 2>/dev/null; else cat; fi)

exit 0
