variable "name" {
  type = string
}

variable "image" {
  description = "Full ECR image reference with tag. Changing it replaces the instance."
  type        = string
}

variable "ecr_repository_arn" {
  description = "The instance may pull from this repository only."
  type        = string
}

variable "container_port" {
  type    = number
  default = 8080
}

variable "instance_type" {
  description = "Defaults to a free-tier-eligible type."
  type        = string
  default     = "t3.micro"
}

variable "allow_paid_instance_type" {
  description = "Set to true to use an instance type outside the free tier on purpose."
  type        = bool
  default     = false
}

variable "vpc_id" {
  type = string
}

variable "subnet_id" {
  description = "A public subnet; the instance gets a public IP so it can reach ECR without a NAT gateway."
  type        = string
}

variable "allowed_cidrs" {
  description = "Who may reach port 80. Empty means nobody; use SSM port forwarding to test."
  type        = list(string)
  default     = []
}

variable "root_volume_gb" {
  type    = number
  default = 8
}
