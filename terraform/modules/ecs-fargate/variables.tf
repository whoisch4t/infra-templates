variable "name" {
  description = "Name for the cluster, service, roles and log group."
  type        = string
}

variable "image" {
  description = "Full image reference, e.g. <account>.dkr.ecr.<region>.amazonaws.com/app:1.0.0."
  type        = string
}

variable "container_port" {
  type    = number
  default = 8080
}

variable "cpu" {
  description = "Task CPU units. 256 = 0.25 vCPU, the smallest Fargate size."
  type        = number
  default     = 256
  validation {
    condition     = contains([256, 512, 1024, 2048, 4096], var.cpu)
    error_message = "cpu must be one of 256, 512, 1024, 2048, 4096."
  }
}

variable "memory" {
  description = "Task memory in MiB. 512 is the smallest that works with 256 CPU."
  type        = number
  default     = 512
}

variable "cpu_architecture" {
  description = "ARM64 is about 20% cheaper on Fargate, but the image must be built for arm64."
  type        = string
  default     = "X86_64"
  validation {
    condition     = contains(["X86_64", "ARM64"], var.cpu_architecture)
    error_message = "cpu_architecture must be X86_64 or ARM64."
  }
}

variable "desired_count" {
  type    = number
  default = 1
  validation {
    condition     = var.desired_count >= 0 && var.desired_count <= 3
    error_message = "desired_count above 3 is outside what these templates were costed for; raise the limit on purpose."
  }
}

variable "use_spot" {
  description = "Run on Fargate Spot (up to ~70% cheaper, can be interrupted with 2 minutes' notice)."
  type        = bool
  default     = false
}

variable "vpc_id" {
  type = string
}

variable "subnet_ids" {
  description = "Public subnets. Tasks get a public IP to pull from ECR, which avoids a NAT gateway (~$32/month)."
  type        = list(string)
}

variable "allowed_cidrs" {
  description = "Who may reach the container port. Empty means nobody from outside the VPC."
  type        = list(string)
  default     = []
}

variable "environment" {
  description = "Plain environment variables for the container. Use Secrets Manager or SSM for secrets."
  type        = map(string)
  default     = {}
}

variable "log_retention_days" {
  type    = number
  default = 7
}
