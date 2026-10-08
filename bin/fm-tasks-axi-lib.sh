# shellcheck shell=bash
# Shared tasks-axi backend selection and compatibility probe for bootstrap,
# teardown, and secondmate backlog handoff.
# Usage: . bin/fm-tasks-axi-lib.sh
#
# Compatible means tasks-axi --version reports FM_TASKS_AXI_MIN or newer,
# `tasks-axi update --help` exposes --archive-body for recoverable note rewrites,
# and `tasks-axi mv --help` exposes [<id>...] for atomic multi-ID moves required
# by secondmate handoffs.
# FM_TASKS_AXI_MIN follows the axi-family floor policy owned beside the floor
# constants in bin/fm-bootstrap.sh.
# The feature probes are a separate concern and stay as defense in depth for
# stripped or forked builds that advertise a current version without those flags.
# `config/backlog-backend=manual` opts out of tasks-axi for routine firstmate
# backlog mutations, but validated secondmate handoffs always use `tasks-axi mv`.
# Absent or any other value keeps the default tasks-axi backend path, falling
# back to manual mutation when the tool is not compatible.
# fm_tasks_axi_backend_resolve owns backend precedence: TASKS_AXI_BACKEND when
# set, then a backend in the working root's .tasks.toml, then one in
# $HOME/.tasks-axi/config.toml, then markdown. Lower-priority sources are read
# only when no earlier source supplies a backend; absent files keep that fallback.
# A detected unreadable or nonregular configuration file, including a dangling
# symlink, returns 2 with a path diagnostic on stderr and no backend on stdout.
# fm_tasks_axi_backend delegates to that resolver and preserves its status;
# callers must check it before selecting backend-specific flags or exemptions.
#
# This file is the single owner of FM_TASKS_AXI_MIN. bin/fm-bootstrap.sh turns a
# failing check into the operator-facing MISSING diagnostic.
#
# COMPATIBILITY VERDICT REUSE. fm_tasks_axi_compatible costs three tasks-axi
# subprocesses, and one session start needs the same verdict twice: once in
# bin/fm-session-start.sh's backlog listing and once in the bin/fm-bootstrap.sh
# child it runs. Two reuse layers collapse that to a single probe:
#   - Within a process the first probe's answer is memoised.
#   - Across ONE process hop, a parent that already holds the verdict passes it
#     in FM_TASKS_AXI_COMPATIBLE=0|1. Sourcing this file CONSUMES that variable
#     (it is unset from the environment and kept only as a private shell
#     variable), so the verdict reaches the child that needs it and never leaks
#     onward into a spawned agent's environment, where it could outlive a
#     tasks-axi upgrade. Any value other than exactly 0 or 1 is ignored and the
#     probe runs normally.
#   - A parent whose probe hit its caller-supplied bound passes
#     FM_TASKS_AXI_TIMED_OUT=1 beside the verdict so the child can name that
#     bound when it reports the failure; consumed with the same one-hop rule.
#   - Each probe takes an optional timeout in seconds: passed to fm_run_timed,
#     it bounds the one tasks-axi shell-out the probe makes. A probe that hits
#     its bound fails like any other unreadable answer and latches
#     FM_TASKS_AXI_PROBE_TIMED_OUT=1, which fm_tasks_axi_probe_timed_out reads
#     so the caller can name the bound instead of reporting a plain
#     incompatibility. The bound itself travels as the probe's 124/137 exit
#     status, because the version probe's output is captured in a command
#     substitution whose variable assignments would never reach the caller.
# Both reuse layers are bounded by process lifetime, so a tasks-axi install or
# upgrade is picked up by the next process rather than being cached to disk.

FM_TASKS_AXI_MIN=0.2.6

FM_TASKS_AXI_COMPATIBLE_MEMO=${FM_TASKS_AXI_COMPATIBLE:-}
unset FM_TASKS_AXI_COMPATIBLE
case "$FM_TASKS_AXI_COMPATIBLE_MEMO" in
  0|1) ;;
  *) FM_TASKS_AXI_COMPATIBLE_MEMO= ;;
esac

FM_TASKS_AXI_TIMED_OUT_MEMO=${FM_TASKS_AXI_TIMED_OUT:-}
unset FM_TASKS_AXI_TIMED_OUT
case "$FM_TASKS_AXI_TIMED_OUT_MEMO" in
  1) ;;
  *) FM_TASKS_AXI_TIMED_OUT_MEMO= ;;
esac

FM_TASKS_AXI_PROBE_TIMED_OUT=

# One tasks-axi shell-out shared by the three probes below: prints the
# command's output and fails nonzero like the command. $1 is the timeout in
# seconds (empty = unbounded), $2 is the stderr mode ('merge' for 2>&1, else
# /dev/null), and $3 onward is the tasks-axi subcommand line. In bounded mode
# the command's status is returned verbatim, so a caller can read fm_run_timed's
# 124/137 bound marker; in unbounded mode any failure collapses to 1.
fm_tasks_axi_probe_run() {  # <timeout> <stderr-mode> <args...>
  local timeout=$1 stderr_mode=$2 output status
  shift 2
  command -v tasks-axi >/dev/null 2>&1 || return 1
  if [ -z "$timeout" ]; then
    if [ "$stderr_mode" = merge ]; then
      tasks-axi "$@" 2>&1 || return 1
    else
      tasks-axi "$@" 2>/dev/null || return 1
    fi
    return 0
  fi
  case "$timeout" in
    ''|*[!0-9]*|0) return 1 ;;
  esac
  [ "$(type -t fm_run_timed)" = function ] || return 1
  if [ "$stderr_mode" = merge ]; then
    output=$(fm_run_timed "$timeout" tasks-axi "$@" 2>&1)
  else
    output=$(fm_run_timed "$timeout" tasks-axi "$@" 2>/dev/null)
  fi
  status=$?
  [ "$status" -eq 0 ] || return "$status"
  printf '%s\n' "$output"
}

fm_tasks_axi_version_parts() {  # [timeout]
  local timeout=${1:-} output status
  output=$(fm_tasks_axi_probe_run "$timeout" quiet --version)
  status=$?
  if [ "$status" -ne 0 ]; then
    # The 124/137 bound marker must survive this command-substitution boundary
    # as a status; a flag set inside it would die with the subshell.
    [ -n "$timeout" ] && fm_timed_out "$status" && return "$status"
    return 1
  fi
  printf '%s\n' "$output" |
    sed -n 's/.*\([0-9][0-9]*\)\.\([0-9][0-9]*\)\.\([0-9][0-9]*\).*/\1 \2 \3/p' |
    head -1
}

fm_tasks_axi_compatible() {  # [timeout]
  case "$FM_TASKS_AXI_COMPATIBLE_MEMO" in
    1) return 0 ;;
    0) return 1 ;;
  esac
  FM_TASKS_AXI_PROBE_TIMED_OUT=
  if fm_tasks_axi_compatible_probe "${1:-}"; then
    FM_TASKS_AXI_COMPATIBLE_MEMO=1
    return 0
  fi
  FM_TASKS_AXI_COMPATIBLE_MEMO=0
  return 1
}

# True only when the tasks-axi compatibility verdict came from a probe that hit
# its caller-supplied bound (in this process or handed down with the verdict),
# so the caller can name that bound when it reports the failure.
fm_tasks_axi_probe_timed_out() {  # [timeout]
  fm_tasks_axi_compatible "${1:-}" && return 1
  [ "$FM_TASKS_AXI_TIMED_OUT_MEMO" = 1 ] || [ "$FM_TASKS_AXI_PROBE_TIMED_OUT" = 1 ]
}

fm_tasks_axi_compatible_probe() {  # [timeout]
  local timeout=${1:-} parts major minor patch extra status
  local min_major min_minor min_patch min_extra
  parts=$(fm_tasks_axi_version_parts "$timeout")
  status=$?
  if [ "$status" -ne 0 ]; then
    [ -n "$timeout" ] && fm_timed_out "$status" && FM_TASKS_AXI_PROBE_TIMED_OUT=1
    return 1
  fi
  [ -n "$parts" ] || return 1
  IFS=' ' read -r major minor patch extra <<< "$parts"
  # An unparseable version is incompatible, never assumed current, so a
  # development or vendored build cannot pass a floor it was never checked against.
  [ -n "$major" ] && [ -n "$minor" ] && [ -n "$patch" ] && [ -z "$extra" ] || return 1
  IFS='.' read -r min_major min_minor min_patch min_extra <<< "$FM_TASKS_AXI_MIN"
  [ -n "$min_major" ] && [ -n "$min_minor" ] && [ -n "$min_patch" ] && [ -z "$min_extra" ] || return 1
  if [ "$major" -gt "$min_major" ] ||
    { [ "$major" -eq "$min_major" ] && [ "$minor" -gt "$min_minor" ]; } ||
    { [ "$major" -eq "$min_major" ] && [ "$minor" -eq "$min_minor" ] && [ "$patch" -ge "$min_patch" ]; }; then
    fm_tasks_axi_update_has_archive_body "$timeout" && fm_tasks_axi_mv_has_multi_id "$timeout"
    return $?
  fi
  return 1
}

fm_tasks_axi_update_has_archive_body() {  # [timeout]
  local timeout=${1:-} output status
  output=$(fm_tasks_axi_probe_run "$timeout" merge update --help)
  status=$?
  if [ "$status" -ne 0 ]; then
    [ -n "$timeout" ] && fm_timed_out "$status" && FM_TASKS_AXI_PROBE_TIMED_OUT=1
    return 1
  fi
  printf '%s\n' "$output" | grep -F -- '--archive-body' >/dev/null
}

fm_tasks_axi_mv_has_multi_id() {  # [timeout]
  local timeout=${1:-} output status
  output=$(fm_tasks_axi_probe_run "$timeout" merge mv --help)
  status=$?
  if [ "$status" -ne 0 ]; then
    [ -n "$timeout" ] && fm_timed_out "$status" && FM_TASKS_AXI_PROBE_TIMED_OUT=1
    return 1
  fi
  printf '%s\n' "$output" | grep -F -- '[<id>...]' >/dev/null
}

fm_tasks_axi_backend_from_toml() {  # <toml-path>
  local toml=$1
  [ -f "$toml" ] || return 1
  LC_ALL=C awk '
    function trim(value) {
      sub(/^[[:space:]]+/, "", value)
      sub(/[[:space:]]+$/, "", value)
      return value
    }
    BEGIN { root=1; found=0; single=sprintf("%c", 39) }
    {
      line=$0
      sub(/[[:space:]]*#.*/, "", line)
      line=trim(line)
      if (line ~ /^\[[^]]+\]$/) {
        root=0
        next
      }
      if (root && line ~ /^backend[[:space:]]*=/) {
        sub(/^backend[[:space:]]*=[[:space:]]*/, "", line)
        line=trim(line)
        if ((substr(line, 1, 1) == "\"" && substr(line, length(line), 1) == "\"") ||
            (substr(line, 1, 1) == single && substr(line, length(line), 1) == single)) {
          print substr(line, 2, length(line) - 2)
          found=1
          exit
        }
      }
    }
    END { if (!found) exit 1 }
  ' "$toml"
}

# Resolve the active tasks-axi backend with the same precedence as tasks-axi.
fm_tasks_axi_backend_resolve() {  # <tasks-axi-working-directory>
  local root=$1 backend
  if [ "${TASKS_AXI_BACKEND+x}" = x ]; then
    printf '%s\n' "$TASKS_AXI_BACKEND"
    return 0
  fi
  local config="$root/.tasks.toml"
  if { [ -d "${config%/*}" ] && [ ! -x "${config%/*}" ]; } ||
    { { [ -e "$config" ] || [ -L "$config" ]; } && { [ ! -f "$config" ] || [ ! -r "$config" ]; }; }; then
    printf 'tasks-axi backend configuration cannot be read at %s\n' "$config" >&2
    return 2
  fi
  if backend=$(fm_tasks_axi_backend_from_toml "$config"); then
    printf '%s\n' "$backend"
    return 0
  fi
  if [ -n "${HOME:-}" ]; then
    config="$HOME/.tasks-axi/config.toml"
    if { [ -d "${config%/*}" ] && [ ! -x "${config%/*}" ]; } ||
      { { [ -e "$config" ] || [ -L "$config" ]; } && { [ ! -f "$config" ] || [ ! -r "$config" ]; }; }; then
      printf 'tasks-axi backend configuration cannot be read at %s\n' "$config" >&2
      return 2
    fi
    if backend=$(fm_tasks_axi_backend_from_toml "$config"); then
      printf '%s\n' "$backend"
      return 0
    fi
  fi
  printf '%s\n' markdown
}

fm_tasks_axi_backend() {  # <tasks-axi-working-directory>
  fm_tasks_axi_backend_resolve "$1"
}

fm_backlog_backend_value() {
  local config_dir=$1 backend_file value
  backend_file="$config_dir/backlog-backend"
  if [ -f "$backend_file" ]; then
    value=$(tr -d '[:space:]' < "$backend_file" 2>/dev/null || true)
    [ -n "$value" ] || value=tasks-axi
    printf '%s\n' "$value"
    return 0
  fi
  printf '%s\n' tasks-axi
}

fm_backlog_backend_manual() {
  local config_dir=$1
  [ "$(fm_backlog_backend_value "$config_dir")" = manual ]
}

fm_tasks_axi_backend_available() {
  local config_dir=$1
  fm_backlog_backend_manual "$config_dir" && return 1
  fm_tasks_axi_compatible
}
