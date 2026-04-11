aws_region             = "us-east-1"
prefix                 = "rw-sqs-dlq-test"
dlq_seed_message_count = 3
tags = {
  "env"       = "test"
  "lifecycle" = "deleteme"
  "product"   = "runwhen"
}
