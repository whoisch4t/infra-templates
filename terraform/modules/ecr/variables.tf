variable "name" {
  description = "Repository name."
  type        = string
}

variable "keep_images" {
  description = "How many tagged images to keep. Older ones are deleted to keep storage under the free 500 MB."
  type        = number
  default     = 10
}

variable "force_delete" {
  description = "Allow destroying the repository while it still has images."
  type        = bool
  default     = false
}
