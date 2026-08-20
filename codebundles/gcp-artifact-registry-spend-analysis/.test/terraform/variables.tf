variable "billing_export_table" {
  type        = string
  description = "Existing BigQuery billing export table used for integration tests, as <project>.<dataset>.<table>"
  default     = ""
}
