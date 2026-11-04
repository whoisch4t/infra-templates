variable "region" {
  type    = string
  default = "us-east-1"
}

variable "name" {
  type    = string
  default = "app"
}

variable "compute" {
  description = <<-EOT
    Where the container runs:
      "ec2"     - one free-tier-eligible instance (default; cheapest)
      "fargate" - one ECS Fargate task (not covered by the free tier, ~$9-13/month)
      "none"    - only the ECR repository
  EOT
  type        = string
  default     = "ec2"
  validation {
    condition     = contains(["ec2", "fargate", "none"], var.compute)
    error_message = "compute must be ec2, fargate or none."
  }
}

variable "image_tag" {
  description = "Tag in the ECR repository to run. Push it before applying."
  type        = string
  default     = "1.0.0"
}

variable "allowed_cidrs" {
  description = "CIDRs allowed to reach the app, e.g. [\"203.0.113.7/32\"]. Empty: closed to the internet."
  type        = list(string)
  default     = []
}

variable "fargate_use_spot" {
  type    = bool
  default = false
}
