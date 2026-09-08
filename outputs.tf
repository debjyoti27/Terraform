output "queue_urls" {
  description = "Logical key → SQS queue URL for every main queue"
  value = {
    for key, q in aws_sqs_queue.main : key => q.url
  }
}

output "dlq_urls" {
  description = "Logical key → DLQ URL (only present for queues with dlq=true)"
  value = {
    for key, q in aws_sqs_queue.dlq : key => q.url
  }
}

# env_vars is written to env/<brand>.env by run.sh.
# Layout per queue: env_var_name=<url> (if set), then each extra_env key=value.
# Adding a queue entry with env_var_name / extra_env automatically extends the
# generated file — no manual env maintenance.
output "env_vars" {
  description = "Newline-separated KEY=VALUE lines ready to write to a .env file"
  value = join("\n", flatten([
    for key, q in local.normalized : concat(
      q.env_var_name != null ? ["${q.env_var_name}=${aws_sqs_queue.main[key].url}"] : [],
      [for k, v in q.extra_env : "${k}=${v}"]
    )
  ]))
}
