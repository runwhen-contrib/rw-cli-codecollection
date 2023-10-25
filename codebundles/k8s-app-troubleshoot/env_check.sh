#!/bin/bash
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
    echo "Please set the NAMESPACE, LABELS, REPO_URI and CONTEXT environment variables"
    exit 1
fi

# clone code repo
# search for ENV var in code
# parse recent commits for matching files/lines
# generate url to files
APPLOGS=$(kubectl -n ${NAMESPACE} --context ${CONTEXT} logs -l ${LABELS} --all-containers --tail=50 --limit-bytes=256000 | grep -i env || true)
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
    # Get a list of file paths in the last 10 commits containing the word
    git diff HEAD~$NUM_OF_COMMITS HEAD --name-only -S "$word" >> "$MODIFIED_FILES"
done
MODIFIED_FILES=$(cat "$MODIFIED_FILES" | sort | uniq)
# echo -e $MODIFIED_FILES | sed 's/ /\n/g'

# Temporary file to store results
TEMPFILE=$(mktemp)
# Search for the words and generate GitHub links with line numbers
for word in $changes_to_investigate; do
    grep -rn "$word" . | while IFS=: read -r file line content; do
        # Check if the file is in the list of modified files
        if echo "$MODIFIED_FILES" | sed 's/ /\n/g' | grep -qF "$(basename $file)"; then
            # Convert the file path to a GitHub link with line number
            echo "$GIT_URL/blob/$BRANCH/$file#L$line" >> "$TEMPFILE"
        fi
    done
done

# Sort, make unique and print the results
sort "$TEMPFILE" | uniq
cat "$TEMPFILE"

# Clean up the temporary file
rm "$TEMPFILE"
