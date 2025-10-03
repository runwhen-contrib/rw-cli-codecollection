FROM us-docker.pkg.dev/runwhen-nonprod-shared/public-images/codecollection-devtools:latest
USER root

ENV RUNWHEN_HOME=/home/runwhen
ENV PATH "$PATH:/usr/local/bin:/home/runwhen/.local/bin"

# Set up directories and permissions
RUN mkdir -p $RUNWHEN_HOME/codecollection
WORKDIR $RUNWHEN_HOME/codecollection

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
RUN chown runwhen:0 -R $RUNWHEN_HOME/codecollection

# Switch to runwhen user
USER runwhen