# Test infrastructure (Azure)

Optional Terraform in `terraform/` can provision an NSG and resource group for manual validation of this CodeBundle against a real subscription.

Create `terraform/tf.secret` (not committed) with:

```bash
export ARM_SUBSCRIPTION_ID="..."
export AZ_TENANT_ID="..."
export AZ_CLIENT_ID="..."
export AZ_CLIENT_SECRET="..."
```

Then run `task build-terraform-infra` from this directory after configuring credentials.
