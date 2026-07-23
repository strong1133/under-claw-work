#!/usr/bin/env bash
set -euo pipefail

tracked="$(git ls-files)"
blocked_files="$(printf '%s\n' "$tracked" | grep -E '(^|/)(\.env($|\.)|credentials\.json$|.*\.pem$|.*\.key$)' || true)"
if [[ -n "$blocked_files" ]]; then
  printf 'Blocked credential-like files:\n%s\n' "$blocked_files" >&2
  exit 1
fi

patterns='(BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY|access[_-]?token[[:space:]]*[:=][[:space:]]*[^${(<[:space:]]|api[_-]?key[[:space:]]*[:=][[:space:]]*[^${(<[:space:]]|password[[:space:]]*[:=][[:space:]]*[^${(<[:space:]])'
if git grep -nEI "$patterns" -- $tracked; then
  printf 'Potential credential value detected. Review before push.\n' >&2
  exit 1
fi

printf 'Secret scan passed.\n'
