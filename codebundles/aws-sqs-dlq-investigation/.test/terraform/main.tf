data "aws_caller_identity" "current" {}

# =============================================================================
# Healthy scenario: primary queue + DLQ, DLQ stays empty
# =============================================================================

resource "aws_sqs_queue" "healthy_dlq" {
  name                      = "${var.prefix}-healthy-dlq"
  message_retention_seconds = 86400
  tags                      = var.tags
}

resource "aws_sqs_queue" "healthy_primary" {
  name                      = "${var.prefix}-healthy-primary"
  message_retention_seconds = 86400
  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.healthy_dlq.arn
    maxReceiveCount     = 3
  })
  tags = var.tags
}

resource "aws_sqs_queue_redrive_allow_policy" "healthy_dlq_allow" {
  queue_url = aws_sqs_queue.healthy_dlq.url
  redrive_allow_policy = jsonencode({
    redrivePermission = "byQueue"
    sourceQueueArns   = [aws_sqs_queue.healthy_primary.arn]
  })
}

# =============================================================================
# Unhealthy scenario: primary queue + DLQ with messages, Lambda consumer
# =============================================================================

resource "aws_sqs_queue" "unhealthy_dlq" {
  name                      = "${var.prefix}-unhealthy-dlq"
  message_retention_seconds = 86400
  tags                      = var.tags
}

resource "aws_sqs_queue" "unhealthy_primary" {
  name                      = "${var.prefix}-unhealthy-primary"
  message_retention_seconds = 86400
  visibility_timeout_seconds = 30
  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.unhealthy_dlq.arn
    maxReceiveCount     = 1
  })
  tags = var.tags
}

resource "aws_sqs_queue_redrive_allow_policy" "unhealthy_dlq_allow" {
  queue_url = aws_sqs_queue.unhealthy_dlq.url
  redrive_allow_policy = jsonencode({
    redrivePermission = "byQueue"
    sourceQueueArns   = [aws_sqs_queue.unhealthy_primary.arn]
  })
}

# =============================================================================
# Lambda consumer (intentionally failing) for event-source-mapping discovery
# =============================================================================

resource "aws_iam_role" "lambda_role" {
  name = "${var.prefix}-lambda-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })
  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "lambda_basic" {
  role       = aws_iam_role.lambda_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "lambda_sqs" {
  name = "sqs-access"
  role = aws_iam_role.lambda_role.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "sqs:ReceiveMessage",
        "sqs:DeleteMessage",
        "sqs:GetQueueAttributes"
      ]
      Resource = [
        aws_sqs_queue.unhealthy_primary.arn,
        aws_sqs_queue.unhealthy_dlq.arn
      ]
    }]
  })
}

data "archive_file" "lambda_zip" {
  type        = "zip"
  output_path = "${path.module}/lambda.zip"
  source {
    content  = <<-PYTHON
      import json
      def handler(event, context):
          for record in event.get("Records", []):
              body = record.get("body", "")
              print(f"ERROR: Failed to process SQS message: {body}")
              raise RuntimeError(f"Intentional failure for DLQ test – message body: {body}")
    PYTHON
    filename = "index.py"
  }
}

resource "aws_lambda_function" "failing_consumer" {
  function_name    = "${var.prefix}-failing-consumer"
  handler          = "index.handler"
  runtime          = "python3.12"
  role             = aws_iam_role.lambda_role.arn
  filename         = data.archive_file.lambda_zip.output_path
  source_code_hash = data.archive_file.lambda_zip.output_base64sha256
  timeout          = 10
  tags             = var.tags
}

resource "aws_lambda_event_source_mapping" "sqs_trigger" {
  event_source_arn = aws_sqs_queue.unhealthy_primary.arn
  function_name    = aws_lambda_function.failing_consumer.arn
  batch_size       = 1
  enabled          = false
}

# =============================================================================
# Seed messages into the unhealthy DLQ so the health check finds a backlog
# =============================================================================

resource "null_resource" "seed_dlq_messages" {
  depends_on = [aws_sqs_queue.unhealthy_dlq]

  provisioner "local-exec" {
    command = <<-EOF
      for i in $(seq 1 ${var.dlq_seed_message_count}); do
        aws sqs send-message \
          --queue-url "${aws_sqs_queue.unhealthy_dlq.url}" \
          --message-body "{\"test_id\":$i,\"error\":\"simulated processing failure\",\"timestamp\":\"$(date -u +%%Y-%%m-%%dT%%H:%%M:%%SZ)\"}" \
          --region "${var.aws_region}" \
          --output json > /dev/null
      done
      echo "Seeded ${var.dlq_seed_message_count} messages into ${aws_sqs_queue.unhealthy_dlq.url}"
    EOF
  }
}

# =============================================================================
# Invoke the Lambda once to create CloudWatch log entries with errors
# =============================================================================

resource "null_resource" "invoke_lambda_for_logs" {
  depends_on = [aws_lambda_function.failing_consumer]

  provisioner "local-exec" {
    command = <<-EOF
      aws lambda invoke \
        --function-name "${aws_lambda_function.failing_consumer.function_name}" \
        --payload '{"Records":[{"body":"{\"test\":true,\"error\":\"simulated\"}"}]}' \
        --region "${var.aws_region}" \
        --cli-binary-format raw-in-base64-out \
        /tmp/lambda-invoke-result.json 2>/dev/null || true
      echo "Invoked Lambda to generate CloudWatch error logs"
    EOF
  }
}

# =============================================================================
# Outputs
# =============================================================================

output "healthy_primary_queue_url" {
  value = aws_sqs_queue.healthy_primary.url
}

output "healthy_dlq_url" {
  value = aws_sqs_queue.healthy_dlq.url
}

output "unhealthy_primary_queue_url" {
  value = aws_sqs_queue.unhealthy_primary.url
}

output "unhealthy_dlq_url" {
  value = aws_sqs_queue.unhealthy_dlq.url
}

output "lambda_function_name" {
  value = aws_lambda_function.failing_consumer.function_name
}

output "aws_account_id" {
  value = data.aws_caller_identity.current.account_id
}
