### How to test this codebundle? 

## Prerequisites

The following credentials and configuration are required:

- Jenkins URL
- Jenkins username 
- Jenkins API token

## Configuration

**Infrastructure Deployment**

Purpose: Cloud infrastructure provisioning and management using Terraform

#### Credential Setup

Navigate to the `.test/terraform` directory and configure two secret files for authentication:

`cb.secret` - CloudCustodian and RunWhen Credentials

Create this file with the following environment variables:

	```sh
	export RW_PAT=""
	export RW_WORKSPACE=""
	export RW_API_URL="papi.beta.runwhen.com"

    export JENKINS_URL=""
	export JENKINS_USERNAME=""
	export JENKINS_TOKEN=""
	```


`tf.secret` - Terraform Deployment Credentials

Create this file with the following environment variables:

	```sh
	export AWS_DEFAULT_REGION=""
	export AWS_ACCESS_KEY_ID=""
	export AWS_SECRET_ACCESS_KEY=""
	export AWS_SESSION_TOKEN="" # Optional: Include if using temporary credentials
	```

####  Testing Workflow

1. Build test infra:
	```sh
		task build-infra
	```	

2. Configure Jenkins and create pipelines:

	- **Initial Setup**: Follow the Jenkins UI prompts to install suggested plugins.

	- **Reproducing Scenarios**:

	  - **Failed Pipeline Logs**:
		 Create a `Freestyle project` and choose the `Execute shell` option under `Build Steps` with an arbitrary script that will fail, such as a syntax error.

	  - **Long Running Pipelines**:
		 Create a `Freestyle project` and choose the `Execute shell` option under `Build Steps`. Use the following script:
		 ```sh
		 #!/bin/bash

		 # Print the start time
		 echo "Script started at: $(date)"

		 # Sleep for 30 minutes (1800 seconds)
		 sleep 1800

		 # Print the end time
		 echo "Script ended at: $(date)"
		 ```

	  - **Queued Builds**:
		 Create three `Freestyle projects` using the above long-running script. With the default Jenkins setup having two executors, triggering all three projects will result in one being queued for a long time.

	  - **Failed Tests**:
		 Create a `Pipeline` project and under the Definition section, paste the following Groovy script:
		 ```groovy
			pipeline {
				agent any

				tools {
					// Install the Maven version configured as "M3" and add it to the path.
					maven "M3"
				}

				stages {
					stage('Build') {
						steps {
							// Get some code from a GitHub repository
							git 'https://github.com/saurabh3460/simple-maven-project-with-tests.git'

							// Run Maven on a Unix agent.
							sh "mvn -Dmaven.test.failure.ignore=true clean package"

							// To run Maven on a Windows agent, use
							// bat "mvn -Dmaven.test.failure.ignore=true clean package"
						}

						post {
							// If Maven was able to run the tests, even if some of the test
							// failed, record the test results and archive the jar file.
							success {
								junit '**/target/surefire-reports/TEST-*.xml'
								archiveArtifacts 'target/*.jar'
							}
						}
					}
				}
			}
		 ```


3. Generate RunWhen Configurations
	```sh
		tasks
	```

4. Upload generated SLx to RunWhen Platform

	```sh
		task upload-slxs
	```

5. At last, after testing, clean up the test infrastructure.

	```sh
		task clean
	```

