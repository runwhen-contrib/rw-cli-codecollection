resource_group = "azure-data-factory-health"
name           = "adf-hlth"
location       = "Canada Central"
table_name     = "dbo.NonExistentTable"
tags = {
  "env" : "test",
  "lifecycle" : "deleteme",
  "product" : "runwhen"
}