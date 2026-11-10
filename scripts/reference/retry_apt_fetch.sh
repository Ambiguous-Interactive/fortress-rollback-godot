#!/usr/bin/env bash
# Run one apt-backed package-acquisition command; retry it exactly once when
# the captured log shows apt's dropped-archive summary. The gate is the log
# signature rather than the wrapped command's own exit code: playwright
# install-deps maps apt's exit 100 to its own exit 1. Mirror preparation,
# signature checks and every verification step stay outside this wrapper.
set -uo pipefail

if (( $# == 0 )); then
  echo 'Expected the package-acquisition command to run.' >&2
  exit 64
fi

log="$(mktemp "${TMPDIR:-/tmp}/apt-fetch.XXXXXX")"
trap 'rm -f -- "$log"' EXIT

run_attempt() {
  local attempt="$1"; shift
  echo "APT package-acquisition attempt ${attempt}: $*"
  "$@" 2>&1 | tee "$log"
}

report_dropped() {
  dropped="$(sed -n 's/^E: Failed to fetch //p' "$log" | awk '{print $1}' \
    | sed -e 's|.*/||' -e 's|?.*||' | sort -u | paste -sd ' ' -)"
  if [[ -n "$dropped" ]]; then
    echo "APT dropped these archive fetches: ${dropped}" >&2
  else
    echo 'APT reported dropped archives without naming them in the captured log.' >&2
  fi
}

run_attempt 1 "$@"
status=$?
if (( status == 0 )); then
  echo "Package acquisition completed on attempt 1 of 2."
  exit 0
fi
if ! grep -q 'Unable to fetch some archives' "$log"; then
  echo "Package acquisition failed with exit ${status}; the log shows no dropped-archive summary, so there is no retry." >&2
  exit "$status"
fi
report_dropped
echo "Retrying the identical package-acquisition command once (attempt 2 of 2)." >&2
run_attempt 2 "$@"
status=$?
if (( status != 0 )); then
  echo "Package acquisition failed again on attempt 2 of 2 with exit ${status}." >&2
  exit "$status"
fi
echo "Package acquisition completed on attempt 2 of 2 after the dropped-archive retry."
