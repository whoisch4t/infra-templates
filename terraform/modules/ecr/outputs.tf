output "repository_url" {
  description = "Push images here: <url>:<tag>."
  value       = aws_ecr_repository.this.repository_url
}

output "repository_arn" {
  value = aws_ecr_repository.this.arn
}
