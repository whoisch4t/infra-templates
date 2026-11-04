output "instance_id" {
  description = "Connect with: aws ssm start-session --target <id>"
  value       = aws_instance.this.id
}

output "public_ip" {
  value = aws_instance.this.public_ip
}
