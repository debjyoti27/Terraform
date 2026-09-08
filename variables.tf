variable "region" {
  type    = string
  default = "ap-south-1"
}

variable "profile" {
  type        = string
  description = "AWS CLI profile — overridden per-account by run.sh"
}

variable "brand" {
  type        = string
  description = "Queue name suffix — overridden per-account by run.sh"
}

# accounts replaces the old flat `brands` list.
# profile = AWS CLI profile name (must match ~/.aws/config exactly)
# brand   = suffix added to every queue name
# One profile can serve multiple brands (same AWS account, different queue suffixes).
variable "accounts" {
  type = list(object({
    profile = string
    brand   = string
  }))
  default     = []
  description = "All accounts/brands to deploy to. Edit this in terraform.tfvars — run.sh reads it from there."
}

# queue_defaults applies to every queue in the map.
# A queue block only needs to set fields that differ from these values.
variable "queue_defaults" {
  type = object({
    dlq                        = optional(bool, true)
    fifo                       = optional(bool, false)
    use_aws_defaults           = optional(bool, false)
    visibility_timeout_seconds = optional(number, 60)
    message_retention_seconds  = optional(number, 1209600)
    receive_wait_time_seconds  = optional(number, 20)
    delay_seconds              = optional(number, 0)
    max_message_size           = optional(number, 262144)
    max_receive_count          = optional(number, 3)
    sse_managed                = optional(bool, true)
  })
  default     = {}
  description = "Default values for every queue. Override per-queue by setting the field in that queue's block."
}

variable "queues" {
  type = map(object({
    # All fields are optional — unset fields fall back to queue_defaults.
    dlq                         = optional(bool)
    fifo                        = optional(bool)
    use_aws_defaults            = optional(bool)
    visibility_timeout_seconds  = optional(number)
    message_retention_seconds   = optional(number)
    receive_wait_time_seconds   = optional(number)
    delay_seconds               = optional(number)
    max_message_size            = optional(number)
    max_receive_count           = optional(number)
    content_based_deduplication = optional(bool, false)
    sse_managed                 = optional(bool)
    queue_name                  = optional(string)
    dlq_name                    = optional(string)
    env_var_name                = optional(string)
    extra_env                   = optional(map(string), {})
  }))
  description = "Queue definitions. Add one entry to add a queue — no .tf edits needed."
}
