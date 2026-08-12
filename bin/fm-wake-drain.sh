#!/usr/bin/env bash
# Atomically drain durable watcher wake records, then assert watcher liveness.
#
# Output is two blocks. First the durable records themselves, unchanged - they
# are the lossless log and every existing consumer keeps reading them. Then a
# WAKE BRIEF: one compact actionable line per record (bin/fm-wake-brief.sh),
# folding in the reads a supervisor otherwise makes by hand for every single
# wake - the status file, the meta, and the crew's current state. That is the
# default one-read path: act from the brief, and reach for bin/fm-crew-state.sh,
# bin/fm-peek.sh, or bin/fm-fleet-view.sh only when a brief line says to.
# Set FM_WAKE_BRIEF=0 to print records only; the brief never changes the drain's
# exit status, and a brief failure is never allowed to fail a drain.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

DRAIN_TMP=
DEDUPED=
DRAIN_LOCK_HELD=false

# Defense in depth for the supervision chain: this script runs at the top of
# every wake-handling and recovery turn, so assert watcher liveness here too. A
# lapsed supervision chain then surfaces on a plain drain-and-handle turn, not
# only when a guarded supervision script (fm-peek/fm-send/...) happens to run.
# Reuse fm-guard.sh's existing graced, beacon-based banner (FM_GUARD_GRACE) - do
# not duplicate the beacon math. Because the watcher touches its beacon every
# poll cycle, a normal fire leaves a recent beacon well inside grace and stays
# silent; only a genuine stale-beyond-grace lapse with work in flight warns. Call
# after the queue is emptied so guard never re-prints its own queued-wakes notice
# for the records this run just drained, and never let a guard hiccup change the
# drain's exit status.
assert_watcher_liveness() {
  "$SCRIPT_DIR/fm-guard.sh" || true
}

# shellcheck disable=SC2317,SC2329 # Invoked by trap handlers below.
cleanup() {
  local status=$?
  if [ "$status" -ne 0 ] && [ "$DRAIN_LOCK_HELD" = true ] && [ -n "$DRAIN_TMP" ] && [ -e "$DRAIN_TMP" ]; then
    fm_wake_restore_queue "$DRAIN_TMP" || true
  fi
  [ -n "$DEDUPED" ] && rm -f "$DEDUPED"
  if [ "$DRAIN_LOCK_HELD" = true ]; then
    fm_lock_release "$FM_WAKE_QUEUE_LOCK"
  fi
  exit "$status"
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

fm_lock_acquire_wait "$FM_WAKE_QUEUE_LOCK"
DRAIN_LOCK_HELD=true

if [ ! -s "$FM_WAKE_QUEUE" ]; then
  : > "$FM_WAKE_QUEUE"
  assert_watcher_liveness
  exit 0
fi

DRAIN_TMP="$STATE/.wake-queue.drain.$(fm_current_pid)"
rm -f "$DRAIN_TMP"
mv "$FM_WAKE_QUEUE" "$DRAIN_TMP" || exit 1
: > "$FM_WAKE_QUEUE" || exit 1

DEDUPED="$STATE/.wake-queue.brief.$(fm_current_pid)"
rm -f "$DEDUPED"
fm_wake_print_deduped "$DRAIN_TMP" > "$DEDUPED" || exit "$?"
cat "$DEDUPED"
rm -f "$DRAIN_TMP"
DRAIN_TMP=

# Release the queue lock BEFORE briefing. The queue is already swapped out and
# emptied, so nothing below needs it, and briefing may shell out per task -
# holding the lock across that would stall the watcher's own fm_wake_append.
fm_lock_release "$FM_WAKE_QUEUE_LOCK"
DRAIN_LOCK_HELD=false

if [ "${FM_WAKE_BRIEF:-1}" != 0 ] && [ -s "$DEDUPED" ]; then
  printf -- '--- wake brief (one line per wake; act from these) ---\n'
  "$SCRIPT_DIR/fm-wake-brief.sh" "$DEDUPED" || true
  printf -- '--- end wake brief ---\n'
fi
rm -f "$DEDUPED"
DEDUPED=
assert_watcher_liveness
exit 0
