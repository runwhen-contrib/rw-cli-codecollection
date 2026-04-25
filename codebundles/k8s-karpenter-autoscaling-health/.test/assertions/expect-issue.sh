#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Tiny assertion helper for CodeBundle *_issues.json output.
#
# Usage:
#   expect-issue.sh <issues-json-file> <title-substring> [<title-substring> ...]
#     Asserts each substring appears in at least one object's .title.
#
#   expect-issue.sh --count <issues-json-file> <expected-count>
#     Asserts the array length equals <expected-count>.
#
#   expect-issue.sh --empty <issues-json-file>
#     Asserts the array is [].
#
#   expect-issue.sh --not-contains <issues-json-file> <title-substring> ...
#     Asserts each substring does NOT appear in any .title.
#
# Exits non-zero on assertion failure, with a clear diff of actual titles.
# ---------------------------------------------------------------------------
set -euo pipefail

die() {
  echo "ASSERTION FAILED: $*" >&2
  exit 1
}

read_titles() {
  local file="$1"
  [[ -s "$file" ]] || die "issues file is missing or empty: $file"
  jq -r '.[]?.title // empty' "$file"
}

mode="${1:-}"
case "$mode" in
  --count)
    file="${2:?file required}"
    expected="${3:?expected count required}"
    actual=$(jq 'length' "$file")
    if [[ "$actual" -ne "$expected" ]]; then
      die "expected ${expected} issue(s) in ${file}, got ${actual}. Titles:\n$(read_titles "$file")"
    fi
    echo "OK: ${file} has ${expected} issue(s)"
    ;;
  --empty)
    file="${2:?file required}"
    actual=$(jq 'length' "$file")
    if [[ "$actual" -ne 0 ]]; then
      die "expected 0 issues in ${file}, got ${actual}. Titles:\n$(read_titles "$file")"
    fi
    echo "OK: ${file} is empty"
    ;;
  --not-contains)
    file="${2:?file required}"
    shift 2
    titles=$(read_titles "$file" || true)
    for sub in "$@"; do
      if printf '%s\n' "${titles}" | grep -qF -- "${sub}"; then
        die "did not expect '${sub}' in any title. Titles:\n${titles}"
      fi
      echo "OK: ${file} does not contain '${sub}'"
    done
    ;;
  "")
    echo "usage: expect-issue.sh <file> <substring> [...]" >&2
    exit 2
    ;;
  *)
    # default: expect each substring present
    file="$1"
    shift
    titles=$(read_titles "$file" || true)
    for sub in "$@"; do
      if ! printf '%s\n' "${titles}" | grep -qF -- "${sub}"; then
        die "expected '${sub}' in at least one title. Actual titles:\n${titles}"
      fi
      echo "OK: ${file} contains '${sub}'"
    done
    ;;
esac
