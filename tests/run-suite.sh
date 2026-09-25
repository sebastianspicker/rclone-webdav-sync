#!/usr/bin/env bash
# run-suite.sh - shared runner for the tests/unit/*.sh and tests/features/*.sh
# suites. Sourced by tests/unit.sh and tests/features.sh; never run directly.
#
# run_suite LABEL DIR SKIP_LIST ARGS... discovers every "$DIR"/*.sh
# automatically (a new file just has to exist to be picked up), except:
#   - any basename listed in SKIP_LIST (space-separated, no .sh: e.g.
#     "common" for tests/unit, "env" for tests/features) - the
#     known sourced helpers for that directory, never runnable suites, and
#   - any basename starting with "_" - a convention for a sourced helper
#     added later without having to also update SKIP_LIST.
# ARGS is then parsed for an optional "-j N" (default $SCIEBO_TEST_JOBS,
# else the CPU count, else 4) and NAME... (matched against the discovered
# scripts with or without a trailing .sh; an unknown NAME prints an error
# and returns 2).
#
# Every script's combined stdout+stderr is captured into its own temp file so
# a bounded pool of background jobs (reaped with `wait -n -p`, Bash 5.3) can
# run concurrently without interleaving their output; once every script has
# finished, the reports are printed in alphabetical order behind the usual
# `=== name ===` header, so the output is identical regardless of finish
# order or job count. -j 1 still runs one script at a time, just as before,
# it only differs in printing its report after it exits instead of live. A
# timing summary (total wall time, the 5 slowest scripts) follows. Returns 1
# and names the failed scripts when any script exits non-zero, 0 otherwise.
set -uo pipefail

# _suite_default_jobs - $SCIEBO_TEST_JOBS, else the online CPU count, else 4.
_suite_default_jobs() {
  local n="${SCIEBO_TEST_JOBS:-}"
  if [[ "$n" =~ ^[0-9]+$ ]] && [[ "$n" -gt 0 ]]; then
    printf '%s' "$n"
    return 0
  fi
  n="$(getconf _NPROCESSORS_ONLN 2>/dev/null || true)"
  [[ "$n" =~ ^[0-9]+$ ]] || n="$(sysctl -n hw.ncpu 2>/dev/null || true)"
  [[ "$n" =~ ^[0-9]+$ ]] && [[ "$n" -gt 0 ]] || n=4
  printf '%s' "$n"
}

# _suite_elapsed START END - START/END are $EPOCHREALTIME snapshots
# (SSSSSSSSSS.NNNNNN); prints their difference in whole/hundredths seconds
# using only integer arithmetic (no bc/awk float support required).
_suite_elapsed() {
  local start="$1" end="$2"
  local s_sec="${start%.*}" s_us="${start#*.}" e_sec="${end%.*}" e_us="${end#*.}"
  local start_us=$((10#$s_sec * 1000000 + 10#$s_us))
  local end_us=$((10#$e_sec * 1000000 + 10#$e_us))
  local diff_us=$((end_us - start_us))
  ((diff_us >= 0)) || diff_us=0
  printf '%d.%02d' "$((diff_us / 1000000))" "$(((diff_us % 1000000) / 10000))"
}

# _suite_reap_one - block for the next finished job (`wait -n -p`, Bash 5.3),
# record its rc and duration, and drop it from the running count. Bash's
# dynamic scoping makes run_suite's locals (pid_to_name, rc_of, dur_of,
# start_of, running) visible here because this only ever runs while a
# run_suite call is on the stack; it is not meant to be called on its own.
#
# Returns 1 without reaping when `wait` was interrupted by a trapped signal
# (it then leaves finished_pid unset), and 2 when no child is left to wait
# for, so the caller can keep draining after Ctrl-C instead of dying on an
# unbound finished_pid under `set -u`.
_suite_reap_one() {
  local finished_pid="" rc=0
  wait -n -p finished_pid
  rc=$?
  if [[ -z "${finished_pid:-}" || -z "${pid_to_name[$finished_pid]+set}" ]]; then
    ((rc == 127)) && return 2
    return 1
  fi
  local reaped="${pid_to_name[$finished_pid]}"
  rc_of["$reaped"]="$rc"
  dur_of["$reaped"]="$(_suite_elapsed "${start_of[$reaped]}" "$EPOCHREALTIME")"
  unset 'pid_to_name[$finished_pid]'
  running=$((running - 1))
}

# _suite_kill_running - TERM every script still running; installed as
# run_suite's INT/TERM handler (dynamic scoping again reaches pid_to_name)
# so an interrupted run doesn't leave scripts behind in their own process
# group (see the `set -m` comment in run_suite).
# Each script leads its own process group (set -m), so TERM the whole group
# to reach anything the script backgrounded itself; no new scripts start
# once interrupted is set.
_suite_kill_running() {
  local pid
  interrupted=1
  for pid in "${!pid_to_name[@]}"; do
    kill -TERM -- "-$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
  done
}

# run_suite LABEL DIR SKIP_LIST [-j N] [NAME...] - see the file header.
run_suite() {
  local label="$1" dir="$2"
  local -a skip_list=()
  read -ra skip_list <<<"${3:-}"
  shift 3

  local -a available=()
  local script name skip_name skipped
  while IFS= read -r script; do
    name="$(basename "$script" .sh)"
    [[ "$name" == _* ]] && continue
    skipped=0
    for skip_name in "${skip_list[@]:-}"; do
      [[ "$name" == "$skip_name" ]] && skipped=1 && break
    done
    ((skipped)) && continue
    available+=("$name")
  done < <(find "$dir" -maxdepth 1 -name '*.sh' -type f -print | sort)

  local jobs=""
  local -a names=()
  while (($#)); do
    case "$1" in
      -j)
        jobs="${2:-}"
        shift 2
        ;;
      -j*)
        jobs="${1#-j}"
        shift
        ;;
      --)
        shift
        names+=("$@")
        break
        ;;
      -*)
        printf '%s: unknown option: %s\n' "$label" "$1" >&2
        return 2
        ;;
      *)
        names+=("$1")
        shift
        ;;
    esac
  done

  if [[ -z "$jobs" ]]; then
    jobs="$(_suite_default_jobs)"
  elif ! [[ "$jobs" =~ ^[0-9]+$ ]] || [[ "$jobs" -lt 1 ]]; then
    printf '%s: -j wants a positive integer, got [%s]\n' "$label" "$jobs" >&2
    return 2
  fi

  local -a selected=()
  if ((${#names[@]} == 0)); then
    selected=("${available[@]}")
  else
    local wanted found ok
    for wanted in "${names[@]}"; do
      wanted="${wanted%.sh}"
      found=0
      for ok in "${available[@]}"; do
        [[ "$ok" == "$wanted" ]] && found=1 && break
      done
      if ((found == 0)); then
        printf '%s: no such test: %s (looked in %s)\n' "$label" "$wanted" "$dir" >&2
        return 2
      fi
      selected+=("$wanted")
    done
    mapfile -t selected < <(printf '%s\n' "${selected[@]}" | sort -u)
  fi

  local -A outfile_of=() start_of=() dur_of=() rc_of=() pid_to_name=()
  local running=0 interrupted=0 overall_start="$EPOCHREALTIME"

  # set -m (job control) gives every backgrounded script its own process
  # group and default SIGINT/SIGQUIT, matching how it ran in the foreground
  # before this runner existed. Without it, a bash script run as `cmd &` in a
  # non-interactive, job-control-off shell inherits SIGINT ignored, and that
  # disposition survives exec into anything the script itself backgrounds
  # (e.g. notifications --watch, which relies on SIGINT to stop) - such a
  # child never sees the signal and `wait` on it hangs forever. A trap on
  # INT/TERM kills any scripts still running if the runner itself is
  # interrupted, so nothing is left behind in its own process group.
  set -m
  trap _suite_kill_running INT TERM

  for name in "${selected[@]}"; do
    ((interrupted)) && break
    outfile_of["$name"]="$(mktemp "${TMPDIR:-/tmp}/sciebo-suite-out.XXXXXX")"
    start_of["$name"]="$EPOCHREALTIME"
    bash "${dir}/${name}.sh" >"${outfile_of[$name]}" 2>&1 &
    pid_to_name[$!]="$name"
    running=$((running + 1))
    while ((running >= jobs && ! interrupted)); do
      _suite_reap_one || (($? == 1)) || break
    done
  done
  # Drain every started script, including after Ctrl-C (the trap has TERMed
  # them), so the report and temp-file cleanup below always run.
  while ((running > 0)); do
    _suite_reap_one || (($? == 1)) || break
  done

  mapfile -t selected < <(printf '%s\n' "${selected[@]}" | sort)
  local -a failed=()
  for name in "${selected[@]}"; do
    if [[ -z "${outfile_of[$name]:-}" ]]; then
      failed+=("${name}(not-run)")
      continue
    fi
    printf '\n=== %s.sh ===\n' "$name"
    cat "${outfile_of[$name]}"
    rm -f "${outfile_of[$name]}"
    [[ "${rc_of[$name]:-1}" -eq 0 ]] || failed+=("$name")
  done

  printf '\n--- timing (%s) ---\n' "$label"
  printf 'total wall time: %ss\n' "$(_suite_elapsed "$overall_start" "$EPOCHREALTIME")"
  printf 'slowest scripts:\n'
  local dur
  while IFS=$'\t' read -r dur name; do
    printf '  %ss  %s\n' "$dur" "$name"
  done < <(
    for name in "${selected[@]}"; do
      [[ -n "${dur_of[$name]:-}" ]] || continue
      printf '%s\t%s\n' "${dur_of[$name]}" "$name"
    done | sort -t $'\t' -k1,1 -rn | head -n 5
  )

  if ((${#failed[@]} > 0)); then
    printf '\nFAILED: %s\n' "${failed[*]}" >&2
    ((interrupted)) && return 130
    return 1
  fi
  ((interrupted)) && return 130
  return 0
}
