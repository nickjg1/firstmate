# shellcheck shell=bash
# Shared worktree-identity helpers for fm-spawn's post-`treehouse get` worktree
# detection. Usage: . bin/fm-worktree-lib.sh
#
# Background (fm-spawn worktree= regression, twice reproduced 2026-07-05 and
# 2026-07-12): fm-spawn discovers the leased worktree by polling the task pane's
# pane_current_path until it leaves the project checkout. The old accept test -
# "any cwd that differs from the project" - was too weak. During shell startup
# the pane can transiently cd into an UNRELATED git repo before `treehouse get`
# has entered the real worktree: oh-my-zsh's tools/check_for_upgrade.sh runs
# `builtin cd -q "$ZSH"` (=~/.oh-my-zsh, itself a git repo) to check for updates.
# The poll captured that transient path, and validate_spawn_worktree accepted it
# because ~/.oh-my-zsh is a self-consistent git repo whose toplevel is itself and
# differs from the project. So the WRONG path was recorded as worktree= in the
# task meta while the crewmate itself sat in the correct worktree, misdirecting
# every teardown/review/state helper that reads worktree=.
#
# The fix: a captured pane cwd only counts as the leased worktree when it is a
# genuine LINKED worktree of the project - it shares the project's git-common-dir.
# treehouse leases exactly such worktrees ("a pool of reusable git worktrees"),
# so every real lease of the project reports the project's own common dir, while
# an unrelated repo like ~/.oh-my-zsh reports its own and is rejected.

# fm_git_common_abs <dir>: echo the absolute, physically-resolved git-common-dir
# of the git repo at <dir>, or return 1 if <dir> is not inside a work tree.
# --git-common-dir is the shared parent-repo git dir for a linked worktree and
# the repo's own .git otherwise; git may print it relative to <dir>, so resolve
# it against <dir> before canonicalizing.
fm_git_common_abs() {  # <dir>
  local dir=$1 common
  common=$(git -C "$dir" rev-parse --git-common-dir 2>/dev/null) || return 1
  [ -n "$common" ] || return 1
  case "$common" in
    /*) : ;;
    *) common="$dir/$common" ;;
  esac
  ( cd "$common" 2>/dev/null && pwd -P ) || return 1
}

# fm_pane_is_leased_worktree <pane-path> <proj-abs-real> <proj-git-common>:
# return 0 iff <pane-path> is inside a genuine linked worktree of the project - a
# git work tree that shares <proj-git-common> and whose toplevel is NOT the
# project's own checkout. <proj-abs-real> is the project's physically-resolved
# path and <proj-git-common> its absolute git-common-dir (fm_git_common_abs).
#
# Both conditions are load-bearing:
#   - shared common dir rejects an unrelated repo the pane transiently entered
#     (e.g. ~/.oh-my-zsh during oh-my-zsh's update check).
#   - toplevel != project rejects the primary checkout itself AND any
#     subdirectory of it (a subdir shares the common dir but resolves to the
#     primary's toplevel), which is the worktree-tangle case.
# Empty and non-git paths return non-zero, so a transient startup cwd never
# passes and the poll keeps waiting for the real `treehouse get`.
fm_pane_is_leased_worktree() {  # <pane-path> <proj-abs-real> <proj-git-common>
  local pane=$1 proj_real=$2 proj_common=$3 pane_common pane_top pane_top_real
  [ -n "$pane" ] || return 1
  [ -n "$proj_common" ] || return 1
  pane_common=$(fm_git_common_abs "$pane") || return 1
  [ "$pane_common" = "$proj_common" ] || return 1
  pane_top=$(git -C "$pane" rev-parse --show-toplevel 2>/dev/null) || return 1
  [ -n "$pane_top" ] || return 1
  pane_top_real=$(cd "$pane_top" 2>/dev/null && pwd -P) || return 1
  [ "$pane_top_real" != "$proj_real" ]
}
