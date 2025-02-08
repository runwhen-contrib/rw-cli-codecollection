#!/usr/bin/env bash
#
# fuzzy_normalize_and_deduplicate.sh
#
# 1) Reads a big multi-line string (via $1 or STDIN).
# 2) Converts any literal "\n" into real newlines.
# 3) Splits on newlines, then normalizes each line by removing timestamps, random IDs, etc.
# 4) Deduplicates the normalized lines, counting how often each occurs.
# 5) Outputs a JSON summary to STDOUT, grouping lines that differ only by ephemeral data.

# set -euo pipefail

# 0) If you want to debug, comment out 'pipefail' or add '|| true'.

###############################################################################
# 1) Capture the input
###############################################################################

if [[ $# -gt 0 ]]; then
  # If the first argument is non-empty, treat it as the entire details string
  input_string="$1"
  # Convert literal "\n" to real newline
  input_string="$(sed 's/\\n/\n/g' <<< "$input_string")"
else
  # Otherwise, read from STDIN
  IFS='' read -r -d '' input_string || true
fi

###############################################################################
# 2) Write the multiline input to a temp variable (no mktemp needed).
#    We'll just store in a shell variable array for convenience, or use a file.
###############################################################################

# Convert the big string into an array of lines in memory:
# (We can do this with a while-read in a subshell.)
mapfile -t all_lines < <(printf "%s" "$input_string")

declare -A line_counts=()

###############################################################################
# 3) Normalize each line to unify lines that differ only by timestamp/ID
###############################################################################

normalize_line() {
  local raw_line="$1"

  # (A) Remove the leading timestamp like "2025-02-08T15:09:25.930134850Z "
  # Adjust this regex to match your real logs:
  # e.g. ^(date/time up to Z ) with optional microseconds.
  local no_timestamp
  no_timestamp="$(sed -E 's/^[0-9T:\.\-]+Z[[:space:]]+//' <<< "$raw_line")"

  # (B) Replace big hex strings (6+ hex chars) with <HEX> if you want lines with random IDs to unify:
  # no_timestamp="$(sed -E 's/[0-9a-fA-F]{6,}/<HEX>/g' <<< "$no_timestamp")"

  # (C) If you want to unify “The Voter <randomstuff>” to “The Voter <ID>”, do:
  no_timestamp="$(sed -E 's/The Voter [0-9a-zA-Z]+/The Voter <ID>/g' <<< "$no_timestamp")"

  # Return the final normalized line
  echo "$no_timestamp"
}

###############################################################################
# 4) Deduplicate lines, counting how often each normalized form appears
###############################################################################

for raw_line in "${all_lines[@]}"; do
  # If the line is empty, skip or consider it a separate line
  # We'll consider blank lines as well:
  # if [[ -z "$raw_line" ]]; then continue; fi

  norm="$(normalize_line "$raw_line")"
  (( line_counts["$norm"]++ ))
done

# Now we have line_counts[norm_line]=count

total_lines=0
unique_norm=0

###############################################################################
# 5) Build a JSON array. We'll do it all at once in memory, then print.
###############################################################################

TMPJSON_OUTPUT=""
TMPJSON_OUTPUT+="["

first_obj=true
for norm_line in "${!line_counts[@]}"; do
  count="${line_counts[$norm_line]}"
  (( total_lines += count ))
  (( unique_norm++ ))

  # JSON-escape the norm_line
  escaped_line="$(jq -Rs . <<< "$norm_line")"
  
  # Build a small JSON object
  if $first_obj; then
    first_obj=false
  else
    TMPJSON_OUTPUT+=","
  fi
  TMPJSON_OUTPUT+="{\"line\": ${escaped_line}, \"count\": ${count}}"
done
TMPJSON_OUTPUT+="]"

# final JSON object with a summary
cat <<EOF
{
  "summary": "Found ${total_lines} lines, ${unique_norm} grouped lines (after normalization)",
  "unique_lines": ${TMPJSON_OUTPUT}
}
EOF
