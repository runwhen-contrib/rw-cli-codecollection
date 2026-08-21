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
#
# A MISSING gcloud IS A DIFFERENT FAILURE, and is reported as one.
#
# The three routes above are all about WHICH credentials to use; none of them
# helps when the binary that would spend them is absent. Before this check, that
# case surfaced two different unhelpful ways:
#
#   * with gcp.json.secret present, the unguarded activate-service-account below
#     died on `"gcloud": executable file not found in $PATH` and exit 127 --
#     no explanation, and a status the caller reports as a task crash;
#   * without it, _ag_have_token swallowed the same 127 via `|| true`, so the
#     run fell through to the credentials advice at the bottom and told the
#     operator to supply credentials they already had.
#
# USUALLY IT IS INSTALLED AND JUST NOT ON PATH.
#
# codecollection-devtools ships the SDK at ~/google-cloud-sdk/bin and puts it on
# PATH via the image's ENV. A LOGIN shell -- `bash -l`, `docker exec -it`, any
# interactive session -- rebuilds PATH from /etc/profile and drops it again, so
# gcloud is present on disk and absent from the shell that needs it. Telling
# someone to install a tool they already have is worse than saying nothing, so
# the check below looks for it before deciding which advice to give.
# -----------------------------------------------------------------------------

if ! command -v gcloud >/dev/null 2>&1; then
    echo "ERROR: gcloud is not on PATH, so no access token can be obtained." >&2
    echo "" >&2
    echo "       This is a TOOLING gap, not a credentials one: every credential" >&2
    echo "       route this script accepts still needs gcloud to spend it, so" >&2
    echo "       adding a key file or logging in will not help." >&2
    echo "" >&2
    _ag_found=""
    for _ag_cand in "${HOME}/google-cloud-sdk/bin" /usr/lib/google-cloud-sdk/bin \
                    /google-cloud-sdk/bin /opt/google-cloud-sdk/bin \
                    /usr/local/google-cloud-sdk/bin; do
        [ -x "${_ag_cand}/gcloud" ] && { _ag_found="${_ag_cand}"; break; }
    done
    if [ -n "${_ag_found}" ]; then
        echo "       It IS installed, at ${_ag_found}/gcloud -- it is just not on" >&2
        echo "       this shell's PATH. A login shell (docker exec -it, bash -l)" >&2
        echo "       rebuilds PATH from /etc/profile and drops what the image set." >&2
        echo "" >&2
        echo "       Fix it for this shell:" >&2
        echo "         export PATH=\"${_ag_found}:\$PATH\"" >&2
    else
        echo "       It does not appear to be installed anywhere this script" >&2
        echo "       knows to look. Install the Google Cloud SDK:" >&2
        echo "         https://cloud.google.com/sdk/docs/install" >&2
    fi
    echo "" >&2
    echo "       Tasks that need no cloud access are unaffected:" >&2
    echo "         task ci    (test-offline, test-render, rule validation, drift)" >&2
    exit 1
fi

_ag_have_token() {
    [ -n "$(gcloud auth print-access-token 2>/dev/null || true)" ]
}

if [ -f "gcp.json.secret" ]; then
    # Checked, not bare: an activation that fails here otherwise falls through to
    # the credentials advice at the bottom, which sends the operator looking for
    # a missing key file when the one they have was rejected.
    if ! gcloud auth activate-service-account --key-file="gcp.json.secret" --quiet; then
        echo "ERROR: .test/gcp.json.secret exists but gcloud rejected it." >&2
        echo "       It is present, so this is not a missing-credentials problem --" >&2
        echo "       check that the file is a complete, unexpired service-account" >&2
        echo "       key in JSON form for a service account that still exists." >&2
        exit 1
    fi
elif _ag_have_token; then
    echo "note: using the already-active gcloud account ($(gcloud config get-value account 2>/dev/null))." >&2
    echo "      .test/gcp.json.secret is still required for run-rwl-discovery." >&2
elif [ -n "${GOOGLE_APPLICATION_CREDENTIALS:-}" ] && [ -f "${GOOGLE_APPLICATION_CREDENTIALS}" ]; then
    echo "note: activating GOOGLE_APPLICATION_CREDENTIALS (${GOOGLE_APPLICATION_CREDENTIALS})." >&2
    if ! gcloud auth activate-service-account --key-file="${GOOGLE_APPLICATION_CREDENTIALS}" --quiet; then
        echo "ERROR: GOOGLE_APPLICATION_CREDENTIALS points at" >&2
        echo "       ${GOOGLE_APPLICATION_CREDENTIALS}, but gcloud rejected it." >&2
        echo "       The file is readable, so this is not a missing-credentials" >&2
        echo "       problem -- check that it is a valid service-account key." >&2
        exit 1
    fi
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
