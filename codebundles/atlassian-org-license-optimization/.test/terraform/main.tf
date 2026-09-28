# Atlassian Cloud organizations cannot be provisioned via Terraform in this test harness.
# Mock fixtures in ../fixtures/ provide deterministic scenario data instead.

output "test_mode" {
  value = "mock-fixtures"
}
