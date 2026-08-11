#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# activate-gcloud.sh -- make sure `gcloud auth print-access-token` will work.
#
# Source this (do not execute it) after load-credentials.sh:
#   . ./activate-gcloud.sh
#
# The thing that actually matters is whether a token can be obtained, so that is
# what this checks. An earlier version demanded .test/gcp.json.secret and exited
# 1 if it was absent -- which blocked runs that were perfectly able to
# authenticate, because tf.secret had already set GOOGLE_APPLICATION_CREDENTIALS
# or the operator was already logged in. Failing hard is right; failing on the
# absence of one particular file, when another valid path exists, is not.
#
# Accepted, in order:
#   1. .test/gcp.json.secret            -- the documented file, also the one
#                                          RunWhen Local needs at /shared
#   2. an already-active gcloud account -- e.g. an operator's own login
#   3. GOOGLE_APPLICATION_CREDENTIALS   -- typically exported by tf.secret
#
# Exits non-zero only when none of them yields a token, naming all three.
# -----------------------------------------------------------------------------

_ag_have_token() {
    [ -n "$(gcloud auth print-access-token 2>/dev/null || true)" ]
}

if [ -f "gcp.json.secret" ]; then
    gcloud auth activate-service-account --key-file="gcp.json.secret" --quiet
elif _ag_have_token; then
    echo "note: using the already-active gcloud account ($(gcloud config get-value account 2>/dev/null))." >&2
    echo "      .test/gcp.json.secret is still required for run-rwl-discovery." >&2
elif [ -n "${GOOGLE_APPLICATION_CREDENTIALS:-}" ] && [ -f "${GOOGLE_APPLICATION_CREDENTIALS}" ]; then
    echo "note: activating GOOGLE_APPLICATION_CREDENTIALS (${GOOGLE_APPLICATION_CREDENTIALS})." >&2
    gcloud auth activate-service-account --key-file="${GOOGLE_APPLICATION_CREDENTIALS}" --quiet
fi

if ! _ag_have_token; then
    echo "ERROR: no usable GCP credentials -- cannot obtain an access token." >&2
    echo "       Provide ONE of:" >&2
    echo "         * .test/gcp.json.secret (also needed later by run-rwl-discovery)" >&2
    echo "         * an active gcloud login (gcloud auth login)" >&2
    echo "         * GOOGLE_APPLICATION_CREDENTIALS pointing at a readable key file" >&2
    echo "       See .test/README.md 'Manual prerequisites'." >&2
    exit 1
fi
