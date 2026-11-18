### How to test this codebundle? 

#### Azure service principal Configuration

We create two distinct Azure service principal with scoped access:


**CloudCustodian Service principal**

Purpose: Service Level Indicator (SLI) monitoring and runbook automation and configured with read only access principles

```sh
AZURE_SUBSCRIPTION_ID=""
az ad sp create-for-rbac --name c7n --role reader --scopes /subscriptions/${AZURE_SUBSCRIPTION_ID}
```

**Infrastructure Deployment Service principal**
Purpose: Cloud infrastructure provisioning and management using Terraform

```sh
AZURE_SUBSCRIPTION_ID=""
az ad sp create-for-rbac --name provisioner --role contributor --scopes /subscriptions/${AZURE_SUBSCRIPTION_ID}
```

# Infrastructure Setup
The terraform directory contains infrastructure used for testing. 


#### Credential Setup

Navigate to the `.test/terraform` directory and configure two secret files for authentication:

`cb.secret` - CloudCustodian and RunWhen Credentials

Create this file with the following environment variables:

	```sh
	export RW_PAT=""
	export RW_WORKSPACE=""
	export RW_API_URL="papi.beta.runwhen.com"

	export ARM_SUBSCRIPTION_ID=""
    export AZ_TENANT_ID=""
    export AZ_CLIENT_SECRET=""
    export AZ_CLIENT_ID=""
	```


`tf.secret` - Terraform Deployment Credentials

Create this file with the following environment variables:

	```sh
	export ARM_SUBSCRIPTION_ID=""
    export AZ_TENANT_ID=""
    export AZ_CLIENT_SECRET=""
    export AZ_CLIENT_ID=""
	```


# Local Development Testing

Perform an azure login on the command line to interact with the infrastructure provisioned by Terraform. 


```sh
az login --service-principal \
    --username "" \
    --password "" \
    --tenant ""
```

####  Testing Workflow

1. Build test infra:
	```sh
		task build-infra
	```	

2. Generate RunWhen Configurations
	```sh
		tasks
	```

3. Upload generated SLx to RunWhen Platform

	```sh
		task upload-slxs
	```

4. At last, after testing, clean up the test infrastructure.

    ```sh
        task clean
    ```
