#!/usr/bin/env bash
# fm-session-start.sh - one command for the whole session start.
#
# Collapses AGENTS.md sections 3 (bootstrap) and 5 (recovery) into ONE script
# producing ONE ordered digest, so a session starts in one or two turns
# instead of the six-plus separate reads the old docs required: run
# fm-bootstrap.sh, then separately read data/projects.md, data/secondmates.md,
# data/captain.md, data/learnings.md, then run fm-lock.sh, fm-wake-drain.sh,
# then read data/backlog.md, every state/*.meta, and every state/*.status.
# Every one of those reads is UNCONDITIONAL at every session start, so they
# belong in a script, not in N agent turns.
#
# COMPOSITION, NOT DUPLICATION: this script calls fm-lock.sh, fm-bootstrap.sh,
# and fm-wake-drain.sh as real subprocesses and prints their real output. It
# never re-implements their logic; all sequencing/formatting logic added here
# stays local to this file. Those three scripts remain fully working
# standalone with unchanged default behavior - other flows (fm-bootstrap.sh
# install <tools> after consent, /updatefirstmate, the afk daemon, existing
# tests) still call them directly. The one seam this script needed -
# bootstrap running its detect-only diagnostics without its four mutating
# sweeps - is an opt-in FM_BOOTSTRAP_DETECT_ONLY=1 flag on fm-bootstrap.sh
# itself (default unset/0 = unchanged behavior), not a fork.
#
# ORDERING, and why LOCK now runs before BOOTSTRAP (the old AGENTS.md order
# was bootstrap-then-lock):
#
#   1. lock          - acquire the per-home session lock FIRST, before any
#                       mutating step runs.
#   2. bootstrap      - detect-only diagnostics always run. The four
#                       MUTATING sweeps (secondmate fast-forward, secondmate
#                       liveness, X-mode artifact writes, fleet sync) run only
#                       when this session actually holds the lock.
#   3. wake-drain     - mutates the durable wake queue, so it also only runs
#                       when locked.
#   4. context digest - data/projects.md, data/secondmates.md, data/captain.md,
#                       data/learnings.md: read-only, always safe, always runs.
#   5. fleet digest   - data/backlog.md, one line per state/*.meta task with its
#                       endpoint liveness and last status EVENT, orphan status
#                       logs, and state/.afk: read-only, always runs.
#
# LEAN BY DEFAULT: this digest is conversation context, so it is re-read on every
# later turn, not just at session start. Sections 4 and 5 therefore summarize
# large inputs and print the exact retrieval command for each; see "digest size
# discipline" below for the rule, the knobs, and what stays verbatim.
#   6. closing reminder - prints the context-specific watcher next step; this
#                       script points back to the emitted harness supervision
#                       block and deliberately never arms the watcher itself.
#
# On a Pi primary, the supervision-block step also checks whether Pi's two
# tracked primary extensions are loaded and prints a PI_WATCH_EXTENSION
# reminder line when one is missing.
#
# Why lock first: the old documented order (bootstrap, THEN lock) let a
# SECOND concurrent session run bootstrap's mutating sweeps - fast-forwarding
# secondmate homes, writing X-mode artifacts, fetching/fast-forwarding every
# project clone - before ever discovering another session already holds the
# lock. Two sessions racing those sweeps is exactly the hazard the lock
# exists to prevent, so locking first closes the hole outright: only the
# session that actually wins the lock ever touches shared mutable state.
#
# The tradeoff this ordering accepts: a refused (read-only) session must not
# go dark. So on refusal, bootstrap still runs (in FM_BOOTSTRAP_DETECT_ONLY=1
# mode) for its read-only detect lines - missing tools, gh auth, the
# worktree-tangle check, the harness override, crew-dispatch validation,
# tasks-axi and quota-axi tool checks, and tasks-axi availability - none of
# which mutate shared state and all of which are safe to compute from a second
# session.
# Only the four mutating sweeps and the wake-queue drain are skipped.
# The context and fleet-state digests
# below are always read-only, so they run unconditionally in both modes.
#
# Usage: fm-session-start.sh
#   Prints the full ordered digest to stdout and always exits 0: this is a
#   reporting command, not a gate. A lock refusal is reported as a loud
#   banner inline, never a silent failure or a non-zero exit that would make
#   an agent skip the rest of the digest.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
PRIMARY_HARNESS=$("$SCRIPT_DIR/fm-harness.sh" 2>/dev/null || printf unknown)

# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"

# Wake-EVENT lines shown per task. One - the last - is what a first turn branches
# on, and the digest prints the command for the rest, so the default is 1 rather
# than the block of 5 this printed before. Raise it when a home genuinely wants
# more history inline; the extra lines print indented under the task line.
STATUS_TAIL=${FM_SESSION_START_STATUS_TAIL:-1}
case "$STATUS_TAIL" in ''|*[!0-9]*|0) STATUS_TAIL=1 ;; esac

# --- digest size discipline -------------------------------------------------
#
# This digest lands in the primary's CONVERSATION, so its cost is not paid once
# at session start: every later turn re-reads the whole thing as context. A home
# whose data/ files have grown to tens of KB therefore pays that tax on every
# single turn, which measurement showed to be the dominant share of orchestrator
# spend. So the digest is LEAN BY DEFAULT: it prints what is needed to act
# correctly on the first turn, and an exact retrieval command for the rest.
#
# What stays verbatim, because it is load-bearing and short: the lock banner,
# bootstrap diagnostics, the wake queue and its brief, the supervision block, the
# ABSENT markers, and the afk flag. What gets summarized: the large data/ files
# and the per-task meta blocks.
#
# A file at or under FULL_BYTES still prints in full, so a small or fresh home
# sees exactly today's digest; only homes big enough for the size to matter get
# a summary. FM_SESSION_START_FULL=1 forces the old whole-file digest.
FULL_BYTES=${FM_SESSION_START_FULL_BYTES:-2000}
case "$FULL_BYTES" in ''|*[!0-9]*) FULL_BYTES=2000 ;; esac
LINE_MAX=${FM_SESSION_START_LINE_MAX:-200}
case "$LINE_MAX" in ''|*[!0-9]*) LINE_MAX=200 ;; esac
INDEX_MAX=${FM_SESSION_START_INDEX_MAX:-40}
case "$INDEX_MAX" in ''|*[!0-9]*) INDEX_MAX=40 ;; esac
FORCE_FULL=${FM_SESSION_START_FULL:-0}

RULE='================================================================================'
SUBRULE='--------------------------------------------------------------------------------'

section() { printf '\n%s\n%s\n%s\n' "$RULE" "$1" "$RULE"; }
subsection() { printf '\n%s\n%s\n' "$1" "$SUBRULE"; }

# Cut a line to LINE_MAX characters, marking any cut so a reader can tell a
# truncated entry from a short one and knows the rest exists.
clip() {
  awk -v max="$LINE_MAX" '{ if (length($0) > max) print substr($0, 1, max) " …"; else print }'
}

clip_routing_entry() {
  awk -v max="$LINE_MAX" '
    function trim_middle(prefix, body, suffix, room) {
      if (length(prefix body suffix) <= max) return prefix body suffix
      room = max - length(prefix) - length(suffix)
      if (room > 2) return prefix substr(body, 1, room - 2) " …" suffix
      return prefix suffix
    }
    {
      line = $0
      open = index(line, " (home: ")
      if (open > 0) {
        identity_match = match(line, /^- [^ ]+ - /)
        if (identity_match > 0) {
          prefix = substr(line, 1, identity_match + RLENGTH - 1)
          body = substr(line, identity_match + RLENGTH, open - identity_match - RLENGTH)
          suffix = substr(line, open)
          print trim_middle(prefix, body, suffix)
          next
        }
      }
      added = index(line, " (added ")
      mode_end = index(line, "] - ")
      if (added > 0 && mode_end > 0) {
        prefix = substr(line, 1, mode_end + 3)
        body = substr(line, mode_end + 4, added - mode_end - 4)
        suffix = substr(line, added)
        print trim_middle(prefix, body, suffix)
        next
      }
      if (length(line) > max) print substr(line, 1, max) " …"
      else print line
    }
  '
}

# file_size <path>: byte count, or 0 when unreadable.
file_size() {
  wc -c < "$1" 2>/dev/null | tr -d '[:space:]'
}

# print_file_header <path> <label>: open the subsection and report presence.
# Prints ABSENT / (present, empty) and returns 1 when there is no body to
# summarize, 0 when the caller should render one. Absence is semantically
# meaningful for every one of these files (captain.md absent = template
# defaults, projects.md absent = rebuild from clones, etc. - AGENTS.md
# section 3) and must never be confused with an empty-but-present file, so
# the two cases print differently and BOTH stay verbatim in the lean digest.
print_file_header() {
  local path=$1 label=$2
  subsection "$label"
  if [ ! -f "$path" ]; then
    printf 'ABSENT\n'
    return 1
  fi
  if [ ! -s "$path" ]; then
    printf '(present, empty)\n'
    return 1
  fi
  return 0
}

# 0 when <path> should print whole: forced full, or small enough that summarizing
# it would save nothing worth the indirection.
print_whole() {
  local path=$1 size
  [ "$FORCE_FULL" = 1 ] && return 0
  size=$(file_size "$path")
  case "$size" in ''|*[!0-9]*) return 0 ;; esac
  [ "$size" -le "$FULL_BYTES" ]
}

# The retrieval pointer every summarized section ends with. Re-reading a
# summarized section on demand is EXPECTED, not a violation of the read-once
# rule: read-once governs the digest's own sections, not a targeted follow-up
# the digest itself told you how to make.
pointer() {  # <what> <command>
  printf '  -> full %s: %s\n' "$1" "$2"
}

# md_index <path>: the file's Markdown headings, one per line, capped at
# INDEX_MAX. For data/learnings.md and data/captain.md the headings ARE the
# index - each names what its section is about - so listing them tells the
# reader exactly which section to retrieve without carrying any body text.
# Falls back to top-level list items for a file with no headings.
md_index() {
  local path=$1 pattern='^#\{1,6\} ' total
  # grep -c both prints 0 and exits 1 on no match, so count through a plain
  # pipeline rather than `grep -c ... || printf 0`, which would concatenate the
  # two zeroes into a bogus "00".
  total=$(grep -c "$pattern" "$path" 2>/dev/null | tr -d '[:space:]')
  case "$total" in ''|*[!0-9]*) total=0 ;; esac
  if [ "$total" -eq 0 ]; then
    pattern='^- '
    total=$(grep -c "$pattern" "$path" 2>/dev/null | tr -d '[:space:]')
    case "$total" in ''|*[!0-9]*) total=0 ;; esac
    [ "$total" -eq 0 ] && { printf '  (no headings or list entries to index)\n'; return 0; }
  fi
  grep "$pattern" "$path" 2>/dev/null | head -n "$INDEX_MAX" | clip | sed 's/^/  /'
  [ "$total" -gt "$INDEX_MAX" ] && printf '  ... %s more (index capped at %s)\n' \
    "$((total - INDEX_MAX))" "$INDEX_MAX"
  return 0
}

# summary_line <path>: the one-line size banner every summarized section opens
# with, so the reader always knows how much was withheld.
summary_line() {
  printf '%s line(s), %s bytes - SUMMARIZED below.\n' \
    "$(grep -c '' "$1" 2>/dev/null || printf '0')" "$(file_size "$1")"
}

# The last wake-EVENT line, clipped, for the inline end of a task line. The full
# log is a targeted follow-up, and the pointer to it is printed once per section.
print_status_last() {
  local status=$1
  if [ -f "$status" ]; then
    grep -v '^[[:space:]]*$' "$status" 2>/dev/null | tail -1 | clip
  else
    printf '(no status file yet)\n'
  fi
}

# The earlier wake EVENTS a raised FM_SESSION_START_STATUS_TAIL asked for, one
# indented line each; silent at the default of 1.
print_status_extra() {
  local status=$1
  [ "$STATUS_TAIL" -gt 1 ] || return 0
  [ -f "$status" ] || return 0
  grep -v '^[[:space:]]*$' "$status" 2>/dev/null \
    | tail -n "$STATUS_TAIL" | sed '$d' | clip | sed 's/^/    earlier: /'
}

hash_file() {
  local file=$1
  [ -f "$file" ] || return 1
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$file" | awk '{print "sha256:" $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$file" | awk '{print "sha256:" $1}'
  else
    cksum "$file" | awk '{print "cksum:" $1 ":" $2}'
  fi
}

pi_extension_loaded() {
  local marker=$1 expected_version=$2 lock=$3 marker_version marker_pid lock_pid
  [ -f "$marker" ] && [ -f "$lock" ] && [ -n "$expected_version" ] || return 1
  marker_version=$(sed -n '1p' "$marker")
  marker_pid=$(sed -n '2p' "$marker")
  lock_pid=$(sed -n '1p' "$lock")
  [ -n "$marker_pid" ] || return 1
  [ "$marker_version" = "$expected_version" ] && [ "$marker_pid" = "$lock_pid" ]
}

section "SESSION START - $FM_HOME"

# --- 1. lock -----------------------------------------------------------
subsection "LOCK"
LOCK_OUT=$("$SCRIPT_DIR/fm-lock.sh" 2>&1)
LOCK_RC=$?
printf '%s\n' "$LOCK_OUT"
READ_ONLY=0
if [ "$LOCK_RC" -ne 0 ]; then
  READ_ONLY=1
  BAR='●━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━'
  {
    printf '%s\n' "$BAR"
    printf '●  READ-ONLY SESSION - ANOTHER LIVE FIRSTMATE SESSION HOLDS THE FLEET LOCK\n'
    printf '●  %s\n' "$LOCK_OUT"
    printf '●  Skipping every mutating step: secondmate sync, X-mode artifacts,\n'
    printf '●  fleet sync, and wake-queue drain. Detect-only bootstrap diagnostics and\n'
    printf '●  the rest of this read-only-safe digest still ran below.\n'
    printf '●  Operate read-only until this resolves - do not spawn, steer, merge, or\n'
    printf '●  otherwise mutate fleet state from this session.\n'
    printf '%s\n' "$BAR"
  }
fi

# --- 2. bootstrap --------------------------------------------------------
subsection "BOOTSTRAP"
if [ "$READ_ONLY" -eq 1 ]; then
  BOOT_OUT=$(FM_BOOTSTRAP_DETECT_ONLY=1 "$SCRIPT_DIR/fm-bootstrap.sh" 2>&1)
else
  BOOT_OUT=$("$SCRIPT_DIR/fm-bootstrap.sh" 2>&1)
fi
if [ -n "$BOOT_OUT" ]; then
  printf '%s\n' "$BOOT_OUT"
else
  printf '(silent - all good)\n'
fi

# --- 3. wake-drain -------------------------------------------------------
# Drained records are this turn's first work queue (AGENTS.md section 8); the
# drain also runs fm-guard.sh internally on the locked path, so the
# tangle/watcher-liveness banners land right here too, ahead of the bulk
# digest below. The read-only path never touches the queue (another session
# may be actively draining it) but still runs fm-guard.sh directly with
# non-mutating advisory text, so the same alarms surface without repair
# commands.
subsection "WAKE QUEUE"
if [ "$READ_ONLY" -eq 1 ]; then
  QLEN=0
  [ -s "$STATE/.wake-queue" ] && QLEN=$(grep -c . "$STATE/.wake-queue" 2>/dev/null || printf '0')
  printf 'skipped (read-only session) - %s record(s) remain queued for the session holding the lock.\n' "$QLEN"
  GUARD_OUT=$(FM_GUARD_READ_ONLY=1 "$SCRIPT_DIR/fm-guard.sh" 2>&1)
  [ -n "$GUARD_OUT" ] && printf '%s\n' "$GUARD_OUT"
else
  DRAIN_OUT=$("$SCRIPT_DIR/fm-wake-drain.sh" 2>&1)
  if [ -n "$DRAIN_OUT" ]; then
    printf '%s\n' "$DRAIN_OUT"
  else
    printf '(no queued wakes)\n'
  fi
fi

# --- 4. supervision operating instructions ----------------------------------
AFK_PRESENT=0
[ -e "$STATE/.afk" ] && AFK_PRESENT=1
X_MODE_PRESENT=0
[ -f "$CONFIG/x-mode.env" ] && X_MODE_PRESENT=1

if [ "$PRIMARY_HARNESS" = pi ]; then
  PI_EXT="$FM_ROOT/.pi/extensions/fm-primary-pi-watch.ts"
  PI_TURNEND_EXT="$FM_ROOT/.pi/extensions/fm-primary-turnend-guard.ts"
  PI_WATCH_MARKER="$STATE/.pi-watch-extension-loaded"
  PI_TURNEND_MARKER="$STATE/.pi-turnend-extension-loaded"
  PI_LOCK="$STATE/.lock"
  PI_WATCH_VERSION=$(hash_file "$PI_EXT" || printf '')
  PI_TURNEND_VERSION=$(hash_file "$PI_TURNEND_EXT" || printf '')
  if ! pi_extension_loaded "$PI_WATCH_MARKER" "$PI_WATCH_VERSION" "$PI_LOCK" \
    || ! pi_extension_loaded "$PI_TURNEND_MARKER" "$PI_TURNEND_VERSION" "$PI_LOCK"; then
    printf 'PI_WATCH_EXTENSION: not loaded - approve Pi project trust once per clone, then restart plain pi so %s and %s auto-load for turn-end guard and background wake coverage; use -e %s -e %s only if project hooks are not trusted\n' "$PI_TURNEND_EXT" "$PI_EXT" "$PI_TURNEND_EXT" "$PI_EXT"
  fi
fi
"$SCRIPT_DIR/fm-supervision-instructions.sh" \
  --harness "$PRIMARY_HARNESS" \
  --read-only "$READ_ONLY" \
  --afk "$AFK_PRESENT" \
  --x-mode "$X_MODE_PRESENT"

# --- 4. context digest -----------------------------------------------------
# The two routing tables (projects, secondmates) keep one line PER ENTRY, because
# intake resolves a project and a secondmate scope from those lines on every
# request. Only each entry's trailing prose is clipped - the identity, mode, and
# scope that do the routing always survive. The two curated knowledge files
# (captain, learnings) are reduced to their heading index, because their headings
# already name what each section covers, so the index is enough to know when to
# go read one.
section "CONTEXT"

if print_file_header "$DATA/projects.md" "data/projects.md"; then
  if print_whole "$DATA/projects.md"; then
    cat "$DATA/projects.md"
  else
    summary_line "$DATA/projects.md"
    printf 'Registry entries (name, mode, +yolo, clipped description):\n'
    grep '^- ' "$DATA/projects.md" 2>/dev/null | clip_routing_entry | sed 's/^/  /'
    pointer "registry" "cat $DATA/projects.md"
  fi
fi

if print_file_header "$DATA/secondmates.md" "data/secondmates.md"; then
  if print_whole "$DATA/secondmates.md"; then
    cat "$DATA/secondmates.md"
  else
    summary_line "$DATA/secondmates.md"
    printf 'Routing table (id, scope, home, clipped):\n'
    grep '^- ' "$DATA/secondmates.md" 2>/dev/null | clip_routing_entry | sed 's/^/  /'
    pointer "routing table" "cat $DATA/secondmates.md"
  fi
fi

if print_file_header "$DATA/captain.md" "data/captain.md"; then
  if print_whole "$DATA/captain.md"; then
    cat "$DATA/captain.md"
  else
    summary_line "$DATA/captain.md"
    printf 'Preference sections (read the one that governs what you are about to do):\n'
    md_index "$DATA/captain.md"
    pointer "captain preferences" "cat $DATA/captain.md"
  fi
fi

if print_file_header "$DATA/learnings.md" "data/learnings.md"; then
  if print_whole "$DATA/learnings.md"; then
    cat "$DATA/learnings.md"
  else
    summary_line "$DATA/learnings.md"
    printf 'Recorded learnings (read one before working in the area it names):\n'
    md_index "$DATA/learnings.md"
    pointer "learnings" "cat $DATA/learnings.md"
  fi
fi

# --- 5. fleet-state digest ---------------------------------------------
section "FLEET STATE"

# The backlog's In-flight section is what a first turn acts on; Queued and Done
# are context for later decisions, so they are reported as counts with the
# command that lists them. The `## In flight` / `## Queued` / `## Done` headings
# are a documented contract (AGENTS.md section 10), which is what makes this
# split safe to compute here rather than guessing at structure.
if print_file_header "$DATA/backlog.md" "data/backlog.md"; then
  if print_whole "$DATA/backlog.md"; then
    cat "$DATA/backlog.md"
  else
    summary_line "$DATA/backlog.md"
    # Only column-zero list items are ITEMS; an indented dash is a note inside
    # the item above it (the backlog's free-form note form), and counting those
    # would both inflate the counts and drag note prose into the digest.
    awk -v max="$LINE_MAX" '
      /^## / { sect = substr($0, 4); counts[sect] = 0; order[++n] = sect; next }
      /^- / {
        if (sect == "") next
        counts[sect]++
        if (sect == "In flight") {
          line = $0
          if (length(line) > max) line = substr(line, 1, max) " …"
          inflight[++f] = line
        }
      }
      END {
        printf "Section counts:"
        for (i = 1; i <= n; i++) printf " %s=%d", order[i], counts[order[i]]
        printf "\n"
        if (f > 0) {
          print "In flight (the queue this turn acts on):"
          for (i = 1; i <= f; i++) print "  " inflight[i]
        }
      }
    ' "$DATA/backlog.md"
    pointer "backlog (queued, done, and item notes)" "cat $DATA/backlog.md"
  fi
fi

# One line per task instead of the whole meta block plus a status tail. The line
# carries every field a first turn actually branches on - kind, mode, backend
# endpoint and its liveness, a recorded PR, and the last wake EVENT - and the
# section prints the retrieval commands for everything else exactly once.
subsection "In-flight tasks (one line per task)"
META_FOUND=0
for meta in "$STATE"/*.meta; do
  [ -f "$meta" ] || continue
  META_FOUND=1
  id=$(basename "$meta" .meta)
  kind=$(fm_meta_get "$meta" kind)
  [ -n "$kind" ] || kind=ship
  mode=$(fm_meta_get "$meta" mode)
  pr=$(fm_meta_get "$meta" pr)
  window=$(fm_meta_get "$meta" window)
  target=$(fm_backend_target_of_meta "$meta")
  if [ -n "$window" ]; then
    backend=$(fm_backend_of_meta "$meta")
    if fm_backend_target_exists "$backend" "${target:-$window}" "fm-$id"; then
      endpoint="alive"
    else
      endpoint="dead"
    fi
    endpoint="$backend $window endpoint=$endpoint"
  else
    endpoint="endpoint=unknown (no window recorded)"
  fi
  printf '%s · %s%s · %s%s · last: %s\n' \
    "$id" "$kind" "${mode:+/$mode}" "$endpoint" "${pr:+ · pr=$pr}" \
    "$(print_status_last "$STATE/$id.status")"
  print_status_extra "$STATE/$id.status"
done
if [ "$META_FOUND" -eq 1 ]; then
  printf '  -> full meta: cat %s/<id>.meta · full wake-event history: cat %s/<id>.status\n' "$STATE" "$STATE"
  printf '  -> LIVE current state (not the event log): bin/fm-crew-state.sh <id> · whole fleet: bin/fm-fleet-view.sh\n'
else
  printf '(none)\n'
fi

subsection "Orphan status logs (state/*.status without matching .meta)"
ORPHAN_STATUS_FOUND=0
for status in "$STATE"/*.status; do
  [ -f "$status" ] || continue
  id=$(basename "$status" .status)
  [ -f "$STATE/$id.meta" ] && continue
  ORPHAN_STATUS_FOUND=1
  printf '%s · last: %s\n' "$id" "$(print_status_last "$status")" | clip
  print_status_extra "$status"
done
[ "$ORPHAN_STATUS_FOUND" -eq 1 ] || printf '(none)\n'

subsection "AFK"
if [ -e "$STATE/.afk" ]; then
  printf 'present - away-mode supervision is active; the daemon owns the watcher.\n'
else
  printf 'absent\n'
fi

# --- 6. closing reminder -----------------------------------------------
section "NEXT STEP"
if [ "$READ_ONLY" -eq 1 ]; then
  cat <<'EOF'
This session did not acquire the fleet lock. Stay read-only: do not arm,
drain, spawn, steer, merge, or repair fleet state from here. The session
holding the lock owns mutable follow-up.

EOF
elif [ "$AFK_PRESENT" -eq 1 ]; then
  cat <<'EOF'
Away mode is active. Follow the supervision operating instructions block above:
load /afk and ensure the daemon is running, because the daemon owns watcher
supervision.

EOF
elif [ -f "$CONFIG/x-mode.env" ]; then
  cat <<EOF
Follow the supervision operating instructions block above for harness '$PRIMARY_HARNESS'.
X mode is active, so the emitted block's cadence instruction applies.
This script never starts supervision itself.

EOF
else
cat <<EOF
Follow the supervision operating instructions block above for harness '$PRIMARY_HARNESS'.
This script never starts supervision itself.

EOF
fi
cat <<'EOF'
The digest above is complete for this session start. It is deliberately LEAN:
large sections were summarized, and each one printed the exact command that
retrieves its full content.

Do NOT bulk-re-read those sources now. A blanket sweep of data/projects.md,
data/secondmates.md, data/captain.md, data/learnings.md, data/backlog.md,
state/*.meta, or state/*.status on this turn defeats the entire point of this
command, and every byte you pull in is re-read as context on every later turn.

DO make a targeted retrieval the moment you need one. Reading a summarized
section on demand is EXPECTED, not a violation: run the printed pointer command
for that one section when you are about to act on what it holds - the captain
preference governing what you are writing, the learning covering the area you
are touching, the queued backlog item you are dispatching, one task's full meta
or wake-event history. Prefer bin/fm-crew-state.sh <id> over any status log when
you want a crew's CURRENT state, and bin/fm-fleet-view.sh for the whole fleet.
Re-read a whole file only when this digest flagged it ABSENT (then rebuild or
create it per AGENTS.md) or its contents looked unparseable or corrupt.
EOF

exit 0
