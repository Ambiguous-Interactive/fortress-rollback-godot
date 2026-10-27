#!/usr/bin/env bash
set -euo pipefail

if (( $# != 2 )) || [[ ! -f "$1" || ! -f "$2" || -L "$2" ]]; then
  echo 'Expected the Ubuntu sources file and a regular mirror-list file.' >&2
  exit 1
fi
sources="$1"
mirrors="$2"
planning="$(mktemp -d "${mirrors}.plan.XXXXXX")"
temporary=""
trap 'rm -rf -- "$planning"; if [[ -n "$temporary" ]]; then rm -f -- "$temporary"; fi' EXIT
mkdir -p "$planning/parts" "$planning/lists/partial" "$planning/cache/archives/partial" "$planning/log"
touch "$planning/empty.conf" "$planning/status"
configuration_path="${planning//\\/\\\\}"
configuration_path="${configuration_path//\"/\\\"}"
printf 'Dir::Etc::Parts "%s/parts";\nDir::Etc::Main "%s/empty.conf";\n' \
  "$configuration_path" "$configuration_path" > "$planning/apt.conf"
if ! APT_CONFIG="$planning/apt.conf" /usr/bin/apt-get --print-uris \
  -o "Dir::Etc::sourcelist=$sources" -o "Dir::Etc::sourceparts=$planning/parts" \
  -o "Dir::State=$planning/state" -o "Dir::State::status=$planning/status" \
  -o "Dir::State::lists=$planning/lists" -o "Dir::Cache=$planning/cache" \
  -o "Dir::Cache::archives=$planning/cache/archives" -o "Dir::Log=$planning/log" \
  -o Debug::NoLocking=1 -o APT::Get::List-Cleanup=0 update > "$planning/uris"; then
  echo 'APT could not plan the supplied Ubuntu sources; mirror list unchanged.' >&2
  exit 1
fi
referenced=false
while IFS= read -r line; do
  if [[ "$line" != \'*\'* ]]; then continue; fi
  planned_uri="${line#\'}"
  planned_uri="${planned_uri%%\'*}"
  planned_base="${planned_uri%/dists/*}"
  if [[ "$planned_base" != "$planned_uri" && "$planned_base" == "mirror+file:${mirrors}" ]]; then
    referenced=true
    break
  fi
done < "$planning/uris"
if [[ "$referenced" != true ]]; then
  echo 'APT does not plan acquisition from the supplied mirror list; list unchanged.' >&2
  exit 1
fi
for host in archive security; do
  if ! grep -Eq "^[[:space:]]*https://${host}\\.ubuntu\\.com/ubuntu/?([[:space:]]|$)" "$mirrors"; then
    echo "Missing trusted HTTPS ${host} mirror; mirror list unchanged." >&2
    exit 1
  fi
done
azure='^[[:space:]]*https?://azure\.archive\.ubuntu\.com(:[0-9]+)?(/|[[:space:]]|$)'
if ! grep -Eq "$azure" "$mirrors"; then
  echo 'Ubuntu HTTPS mirror alternatives are already selected.'
  exit 0
fi
temporary="$(mktemp "${mirrors}.XXXXXX")"
grep -Ev -- "$azure" "$mirrors" > "$temporary"
chmod --reference="$mirrors" "$temporary"
mv -- "$temporary" "$mirrors"
echo 'Removed the Azure preference; retained the existing Ubuntu HTTPS alternatives.'
