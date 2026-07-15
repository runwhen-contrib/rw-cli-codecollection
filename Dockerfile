# Base runtime image — rw-base-runtime ships:
#   - Python 3 + the worker binary + the standard CLI tooling
#     (kubectl, aws, az, gcloud, helm, istioctl, gh, pwsh, jq, yq, skopeo,
#      linear-cli, claude, cursor)
#   - rw-core-keywords pip-installed system-wide (RW.Core / RW.platform /
#     RW.fetchsecrets / etc.)
#   - The robot-runtime helper scripts at /home/runwhen/robot-runtime/
#     (entrypoint.sh, runrobot.{sh,py}, RWP.py, metrics_daemon.py, ...)
#
# Source: https://github.com/runwhen-contrib/rw-base-runtime
#
# Override at build time to pin a specific runtime sha (production tag
# suffix) or to test against a BYO base, e.g.:
#
#   docker build \
#     --build-arg BASE_IMAGE=ghcr.io/runwhen-contrib/rw-base-runtime:<sha7> \
#     ...
#
# The CI workflow (.github/workflows/build-push.yaml) resolves the
# `runtime_ref` dispatch input to an rw-base-runtime commit sha and
# bakes that sha into the resulting image tag suffix.
ARG BASE_IMAGE=ghcr.io/runwhen-contrib/rw-base-runtime:latest
FROM ${BASE_IMAGE}
USER root

# Override rw-core-keywords with the GCP ADC provider fix branch.
# The base image ships rw-core-keywords from PyPI, which is missing the
# gcp:adc / gcp:sa provider match in fetchsecrets.read_secret(). This
# force-reinstalls from the fix branch so the runner can import GCP
# kubeconfig secrets. Remove once the fix is merged and published to PyPI.
#
# Pinned to a commit SHA (not branch name) so Docker layer cache busts
# when the fix is updated — branch-name pins reuse stale cached layers.
RUN pip3 install --no-cache-dir --force-reinstall --no-deps \
    git+https://github.com/runwhen-contrib/rw-core-keywords.git@7545b53

ENV RUNWHEN_HOME=/home/runwhen
ENV PATH "$PATH:/usr/local/bin:/home/runwhen/.local/bin"

# Set up directories and permissions.
#
# Codecollection contents MUST land at ${RUNWHEN_HOME}/collection (NOT
# /codecollection). PAPI emits RW_PATH_TO_ROBOT=$(RUNWHEN_HOME)/collection/
# codebundles/<bundle>/sli.robot and runrobot.{sh,py} only know how to
# resolve under /home/runwhen/collection — a mismatch surfaces as
# `FileNotFoundError: Could not find the robot file in any known locations.`
RUN mkdir -p $RUNWHEN_HOME/collection
WORKDIR $RUNWHEN_HOME/collection

# Copy files into container with correct ownership
COPY --chown=runwhen:0 . .

# Check and install requirements if requirements.txt exists
RUN if [ -f "requirements.txt" ]; then pip install --no-cache-dir -r requirements.txt; else echo "requirements.txt not found, skipping pip install"; fi

# Install additional user packages
#RUN apt-get update && \
#    apt-get install -y --no-install-recommends net-tools && \
#    apt-get clean && \
#    rm -rf /var/lib/apt/lists/* /var/cache/apt

# Add runwhen user to sudoers with no password prompt
RUN echo "runwhen ALL=(ALL) NOPASSWD: ALL" >> /etc/sudoers

# Set RunWhen Temp Dir
RUN mkdir -p /var/tmp/runwhen && chmod 1777 /var/tmp/runwhen
ENV TMPDIR=/var/tmp/runwhen

# Adjust permissions for runwhen user
RUN chown runwhen:0 -R $RUNWHEN_HOME/collection

# Switch to runwhen user
USER runwhen
