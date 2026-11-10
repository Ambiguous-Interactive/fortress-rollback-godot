#!/usr/bin/env bash
# Run one apt-backed package-acquisition command; retry it exactly once when
# apt reports exit 100 with dropped archive fetches. Mirror preparation,
# signature checks and every verification step stay outside this wrapper.
set -u

if (( $# == 0 )); then
  echo 'Expected the package-acquisition command to run.' >&2
  exit 64
fi

log="$(mktemp "${TMPDIR:-/tmp}/apt-fetch.XXXXXX")"
trap 'rm -f -- "$log"' EXIT

run_attempt() {
  local attempt="$1"; shift
  echo "APT package-acquisition attempt ${attempt}: $*"
  "$@" > >(tee "$log") 2>&1
}

run_attempt 1 "$@"
status=$?
if (( status == 0 )); then
  echo "Package acquisition completed on attempt 1 of 2."
  exit 0
fi
if (( status != 100 )) || ! grep -q 'Unable to fetch some archives' "$log"; then
  echo "Package acquisition failed with exit ${status}; the log shows no dropped archives, so there is no retry." >&2
  exit "$status"
fi
dropped="$(sed -n 's/^E: Failed to fetch //p' "$log" | sed 's|.*/||' | sort -u | paste -sd ' ' -)"
echo "APT dropped these archive fetches before exit 100: ${dropped}" >&2
echo "Retrying the identical package-acquisition command once (attempt 2 of 2)." >&2
run_attempt 2 "$@"
status=$?
if (( status != 0 )); then
  echo "Package acquisition failed again on attempt 2 of 2 with exit ${status}." >&2
  exit "$status"
fi
echo "Package acquisition completed on attempt 2 of 2 after the dropped-archive retry."
