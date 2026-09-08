locals {
  # Pass 1 — resolve each queue's effective values.
  # Per-queue field wins if set; otherwise falls back to queue_defaults.
  resolved = {
    for key, q in var.queues : key => {
      dlq              = q.dlq != null ? q.dlq : var.queue_defaults.dlq
      fifo             = q.fifo != null ? q.fifo : var.queue_defaults.fifo
      use_aws_defaults = q.use_aws_defaults != null ? q.use_aws_defaults : var.queue_defaults.use_aws_defaults
      sse_managed      = q.sse_managed != null ? q.sse_managed : var.queue_defaults.sse_managed

      visibility_timeout_seconds = coalesce(q.visibility_timeout_seconds, var.queue_defaults.visibility_timeout_seconds)
      message_retention_seconds  = coalesce(q.message_retention_seconds,  var.queue_defaults.message_retention_seconds)
      receive_wait_time_seconds  = coalesce(q.receive_wait_time_seconds,  var.queue_defaults.receive_wait_time_seconds)
      delay_seconds              = coalesce(q.delay_seconds,              var.queue_defaults.delay_seconds)
      max_message_size           = coalesce(q.max_message_size,           var.queue_defaults.max_message_size)
      max_receive_count          = coalesce(q.max_receive_count,          var.queue_defaults.max_receive_count)

      content_based_deduplication = q.content_based_deduplication
      queue_name   = q.queue_name
      dlq_name     = q.dlq_name
      env_var_name = q.env_var_name
      extra_env    = q.extra_env
    }
  }

  # Pass 2 — compute final names and null-out attributes when use_aws_defaults=true.
  normalized = {
    for key, r in local.resolved : key => {
      # Default naming: <key>-{queue|dlq}-<brand>[.fifo]
      # Override with queue_name / dlq_name in the queue block if needed.
      queue_name = (
        r.queue_name != null
        ? (r.fifo ? "${r.queue_name}.fifo" : r.queue_name)
        : (r.fifo ? "${key}-queue-${var.brand}.fifo" : "${key}-queue-${var.brand}")
      )
      dlq_name = (
        r.dlq_name != null
        ? (r.fifo ? "${r.dlq_name}.fifo" : r.dlq_name)
        : (r.fifo ? "${key}-dlq-${var.brand}.fifo" : "${key}-dlq-${var.brand}")
      )

      fifo = r.fifo
      # content_based_deduplication is only valid on FIFO queues; null = omit.
      content_based_deduplication = r.fifo ? r.content_based_deduplication : null

      # null = Terraform omits the attribute → AWS keeps/applies its own default.
      visibility_timeout_seconds = r.use_aws_defaults ? null : r.visibility_timeout_seconds
      message_retention_seconds  = r.use_aws_defaults ? null : r.message_retention_seconds
      receive_wait_time_seconds  = r.use_aws_defaults ? null : r.receive_wait_time_seconds
      delay_seconds              = r.use_aws_defaults ? null : r.delay_seconds
      max_message_size           = r.use_aws_defaults ? null : r.max_message_size

      sse_managed       = r.sse_managed
      dlq               = r.dlq
      max_receive_count = r.max_receive_count
      env_var_name      = r.env_var_name
      extra_env         = r.extra_env
    }
  }

  dlq_queues = {
    for key, q in local.normalized : key => q if q.dlq
  }
}

resource "aws_sqs_queue" "dlq" {
  for_each = local.dlq_queues

  name                        = each.value.dlq_name
  fifo_queue                  = each.value.fifo
  sqs_managed_sse_enabled     = each.value.sse_managed
  content_based_deduplication = each.value.content_based_deduplication
  visibility_timeout_seconds  = each.value.visibility_timeout_seconds
  message_retention_seconds   = each.value.message_retention_seconds
  receive_wait_time_seconds   = each.value.receive_wait_time_seconds
  delay_seconds               = each.value.delay_seconds
  max_message_size            = each.value.max_message_size

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_sqs_queue" "main" {
  for_each = local.normalized

  name                        = each.value.queue_name
  fifo_queue                  = each.value.fifo
  sqs_managed_sse_enabled     = each.value.sse_managed
  content_based_deduplication = each.value.content_based_deduplication
  visibility_timeout_seconds  = each.value.visibility_timeout_seconds
  message_retention_seconds   = each.value.message_retention_seconds
  receive_wait_time_seconds   = each.value.receive_wait_time_seconds
  delay_seconds               = each.value.delay_seconds
  max_message_size            = each.value.max_message_size

  redrive_policy = each.value.dlq ? jsonencode({
    deadLetterTargetArn = aws_sqs_queue.dlq[each.key].arn
    maxReceiveCount     = each.value.max_receive_count
  }) : null

  lifecycle {
    prevent_destroy = true
  }
}
