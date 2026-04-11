variable "aws_region" {
  description = "AWS region to deploy test resources"
  type        = string
  default     = "us-east-1"
}

variable "prefix" {
  description = "Name prefix for all test resources"
  type        = string
  default     = "rw-sqs-dlq-test"
}

variable "tags" {
  description = "Tags applied to all test resources"
  type        = map(string)
  default = {
    "env"       = "test"
    "lifecycle" = "deleteme"
    "product"   = "runwhen"
  }
}

variable "dlq_seed_message_count" {
  description = "Number of messages to seed into the unhealthy DLQ"
  type        = number
  default     = 3
}
