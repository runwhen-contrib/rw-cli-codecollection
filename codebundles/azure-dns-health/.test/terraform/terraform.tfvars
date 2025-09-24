resource_group = "azure-dns-health"
location       = "East US"

# DNS Configuration
public_domain                = "dns-health-test.azure.runwhen.com"
parent_domain_name           = "azure.runwhen.com"
parent_domain_resource_group = "nonprod-network"

tags = {
  Environment = "test"
  Project     = "dns-health"
  ManagedBy   = "terraform"
}

