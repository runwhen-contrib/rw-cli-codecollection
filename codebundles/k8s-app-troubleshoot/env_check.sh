#!/bin/bash
# -----------------------------------------------------------------------------
# Script Information and Metadata
# -----------------------------------------------------------------------------
# Author: @jon-funk
# Description: This script checks a resource's logs for errors or potential problems 
# related to environment variables and attempts to pinpoint them to recent code changes in the repo.
# -----------------------------------------------------------------------------

# Setup error handling
set -Euo pipefail
# Function to handle errors
function handle_error() {
    local line_number=$1
    local function_name=$2
    local error_code=$3
    echo "Error occurred in function '$function_name' at line $line_number with error code $error_code"
}
# Trap error signals to error handler function
trap 'handle_error $LINENO $FUNCNAME $?' ERR

# Check if kubectl is available
if ! command -v kubectl &> /dev/null; then
    echo "kubectl command not found!"
    exit 1
fi

# Check for namespace argument
if [ -z "$NAMESPACE" ] || [ -z "$CONTEXT" ] || [ -z "$LABELS" ] || [ -z "$REPO_URI" ] || [ -z "$NUM_OF_COMMITS" ]; then
    echo "Please set the NAMESPACE, LABELS, REPO_URI, NUM_OF_COMMITS and CONTEXT environment variables"
    exit 1
fi

APPLOGS=$(kubectl -n ${NAMESPACE} --context ${CONTEXT} logs $(kubectl --context=${CONTEXT} -n ${NAMESPACE} get deployment,statefulset -l ${LABELS} -oname | head -n 1) --all-containers --tail=50 --limit-bytes=256000 | grep -i env || true)
APP_REPO_PATH=/tmp/app_repo
git clone $REPO_URI $APP_REPO_PATH || true
cd $APP_REPO_PATH

changes_to_investigate=""
for word in $APPLOGS; do
    checkpath=$(echo "$word" | tr ' ' '\n' | xargs -I{} grep -rin "{}" | grep -E "environment|env" | grep -oE "[A-Z_]{3,}" | sort | uniq || true)
    changes_to_investigate+="${checkpath}\n"
done;
changes_to_investigate=$(echo -e $changes_to_investigate | sed 's/ /\n/g' | sort | uniq | sed 's/ /\n/g')
# echo -e $changes_to_investigate

GIT_URL=$(git remote get-url origin | sed -E 's/git@github.com:/https:\/\/github.com\//' | sed 's/.git$//')
BRANCH=$(git rev-parse --abbrev-ref HEAD)

# Create git changes filter for final result
MODIFIED_FILES=$(mktemp)
for word in $changes_to_investigate; do
    git diff HEAD~$NUM_OF_COMMITS HEAD --name-only -S "$word" >> "$MODIFIED_FILES"
done
MODIFIED_FILES=$(cat "$MODIFIED_FILES" | sort | uniq)
# echo -e $MODIFIED_FILES | sed 's/ /\n/g'

# Temporary file to store results
TEMPFILE=$(mktemp)
# Search for the words and generate GitHub links with line numbers
for word in $changes_to_investigate; do
    grep -rn "$word" . | while IFS=: read -r file line content; do
        if echo "$MODIFIED_FILES" | sed 's/ /\n/g' | grep -qF "$(basename $file)"; then
            echo "$GIT_URL/blob/$BRANCH/$file#L$line" >> "$TEMPFILE"
        fi
    done
done

# Sort, make unique and print the results
sort "$TEMPFILE" | uniq

if [[ -n "$changes_to_investigate" ]]; then
    echo -e "We found the following Environment variables in the logs, which may indicate a problem with them.\n"
    echo -e $(echo -e $changes_to_investigate  | sed 's/ /\n/g')
    echo -e "\n\n"
else
    echo -e "No potential environment variable issues were found in the recent logs."
fi

if [[ -n "$MODIFIED_FILES" ]]; then
    echo "They appear in the following files changed within the last $NUM_OF_COMMITS commits."
    echo -e $MODIFIED_FILES | sed 's/ /\n/g'
    echo -e "\n\n"
else
    echo -e "No files were found that contain detected potential environment variable issues.\n"
fi


repo_links=$(cat "$TEMPFILE")
# echo $repo_links
echo "Suggested Next Steps:"
if [[ -n "$repo_links" ]]; then
    echo "Investigate the following files for changes related to environment variables"
    echo -e "$repo_links"
else
    echo "No root-cause files could be found with the available information, check the repo $REPO_URI manaually."
fi

# Clean up the temporary file
rm "$TEMPFILE"
