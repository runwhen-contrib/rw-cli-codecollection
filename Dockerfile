FROM us-docker.pkg.dev/runwhen-nonprod-shared/public-images/codecollection-devtools:latest

USER root

RUN mkdir /app/codecollection
COPY . /app/codecollection

RUN pip install -r /app/codecollection/requirements.txt

# Install packages
RUN apt-get update && \
    apt install -y git dnsutils shellcheck && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/* && \
    rm -rf /var/cache/apt

RUN apt-get update && \
    apt-get install -y groff mandoc less && \
    curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip" && \
    unzip awscliv2.zip && \
    ./aws/install && \
    rm awscliv2.zip && \
    rm -rf ./aws && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

# Change the owner of all files inside /app to user and give full permissions
RUN chown 1000:0 -R $WORKDIR
RUN chown 1000:0 -R /app/codecollection

# Set the user to $USER
ENV USER "python"
USER python
