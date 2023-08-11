FROM us-docker.pkg.dev/runwhen-nonprod-shared/public-images/codecollection-devtools:latest

USER root

RUN mkdir /app/codecollection
COPY . /app/codecollection

RUN pip install -r /app/codecollection/requirements.txt

# Install packages
RUN apt-get update && \
    apt install -y git && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/* && \
    rm -rf /var/cache/apt

# Change the owner of all files inside /app to user and give full permissions
RUN chown 1000:0 -R $WORKDIR
RUN chown 1000:0 -R /app/codecollection

# Set the user to $USER
USER python