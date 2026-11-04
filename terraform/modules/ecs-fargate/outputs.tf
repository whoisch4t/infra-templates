output "cluster_name" {
  value = aws_ecs_cluster.this.name
}

output "service_name" {
  value = aws_ecs_service.this.name
}

output "task_definition_arn" {
  description = "Current revision. For a manual rollback, point the service at an older revision."
  value       = aws_ecs_task_definition.this.arn
}

output "log_group" {
  value = aws_cloudwatch_log_group.this.name
}
