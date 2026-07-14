#!/usr/bin/env bash
# Behavior tests for fm-spawn's worktree-identity detection (fm-worktree-lib.sh).
#
# Regression cover for the twice-reproduced worktree= bug (2026-07-05 and
# 2026-07-12): fm-spawn polls the task pane's cwd until it leaves the project,
# then records it as worktree= in the task meta. The old accept test - "any cwd
# that differs from the project" - captured a TRANSIENT startup cwd in an
# unrelated git repo (oh-my-zsh's update check cd's into $ZSH=~/.oh-my-zsh before
# `treehouse get` has entered the real worktree) and recorded ~/.oh-my-zsh as the
# worktree, because that path is a self-consistent git repo. The fix requires the
# captured path to be a genuine LINKED worktree of the project - sharing its
# git-common-dir - which the contaminating repo is not. These cases pin that
# distinction hermetically over real temp git repos.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-worktree-lib.sh
. "$ROOT/bin/fm-worktree-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-spawn-worktree-detect)
fm_git_identity fmtest fmtest@example.invalid

# Physically-resolved path of <dir>, matching fm-spawn's PROJ_ABS_REAL derivation.
real_path() { (cd "$1" && pwd -P); }

# Build the fixture once: a project repo with a linked worktree, plus a separate
# unrelated repo standing in for ~/.oh-my-zsh (the transient startup cwd).
PROJECT="$TMP_ROOT/project"
WORKTREE="$TMP_ROOT/wt-real"
OHMYZSH="$TMP_ROOT/ohmyzsh"
NONGIT="$TMP_ROOT/plain-dir"
fm_git_init_commit "$PROJECT"
git -C "$PROJECT" worktree add --quiet "$WORKTREE"
fm_git_init_commit "$OHMYZSH"
mkdir -p "$NONGIT"

PROJ_REAL=$(real_path "$PROJECT")
PROJ_COMMON=$(fm_git_common_abs "$PROJECT")

# fm_git_common_abs collapses a linked worktree and its parent onto one shared
# common dir, and gives an unrelated repo its own - the whole basis of the fix.
test_git_common_abs_shared() {
  local wt_common omz_common
  [ -n "$PROJ_COMMON" ] || fail "project common dir did not resolve"
  wt_common=$(fm_git_common_abs "$WORKTREE")
  [ "$wt_common" = "$PROJ_COMMON" ] \
    || fail "linked worktree common dir '$wt_common' != project '$PROJ_COMMON'"
  omz_common=$(fm_git_common_abs "$OHMYZSH")
  [ -n "$omz_common" ] || fail "unrelated repo common dir did not resolve"
  [ "$omz_common" != "$PROJ_COMMON" ] \
    || fail "unrelated repo common dir must differ from the project's"
  fm_git_common_abs "$NONGIT" >/dev/null \
    && fail "a non-git dir must not resolve a common dir"
  pass "fm_git_common_abs: linked worktree shares the project's common dir; unrelated repo does not"
}

# The load-bearing regression case: the real worktree is accepted, and the
# ~/.oh-my-zsh-shaped repo (the value that was wrongly recorded) is rejected.
test_leased_worktree_accepts_real_rejects_contaminant() {
  fm_pane_is_leased_worktree "$WORKTREE" "$PROJ_REAL" "$PROJ_COMMON" \
    || fail "the genuine linked worktree must be accepted"
  fm_pane_is_leased_worktree "$OHMYZSH" "$PROJ_REAL" "$PROJ_COMMON" \
    && fail "the unrelated ~/.oh-my-zsh-shaped repo must be rejected (this is the bug)"
  pass "fm_pane_is_leased_worktree: accepts the real worktree, rejects the transient unrelated repo"
}

# A subdirectory of the primary checkout shares the project's common dir but is
# the worktree-tangle case, not a lease: its toplevel is the primary. It must be
# rejected on the toplevel check, or the poll would record a tangled path.
test_leased_worktree_rejects_primary_subdir() {
  mkdir -p "$PROJECT/sub"
  fm_pane_is_leased_worktree "$PROJECT/sub" "$PROJ_REAL" "$PROJ_COMMON" \
    && fail "a subdirectory of the primary checkout must be rejected (tangle case)"
  pass "fm_pane_is_leased_worktree: rejects a subdirectory of the primary checkout"
}

# Every other non-worktree candidate the poll could see must also be rejected, so
# the loop keeps waiting for the real `treehouse get` instead of recording junk.
test_leased_worktree_rejects_edge_cases() {
  fm_pane_is_leased_worktree "$PROJECT" "$PROJ_REAL" "$PROJ_COMMON" \
    && fail "the project checkout itself must be rejected"
  fm_pane_is_leased_worktree "" "$PROJ_REAL" "$PROJ_COMMON" \
    && fail "an empty pane path must be rejected"
  fm_pane_is_leased_worktree "$NONGIT" "$PROJ_REAL" "$PROJ_COMMON" \
    && fail "a non-git directory must be rejected"
  fm_pane_is_leased_worktree "$WORKTREE" "$PROJ_REAL" "" \
    && fail "an empty project common dir must fail closed"
  pass "fm_pane_is_leased_worktree: rejects the project itself, empty, non-git, and unresolved-project cases"
}

test_git_common_abs_shared
test_leased_worktree_accepts_real_rejects_contaminant
test_leased_worktree_rejects_primary_subdir
test_leased_worktree_rejects_edge_cases
