output "ecr_repository_url" {
  value = module.ecr.repository_url
}

output "image" {
  value = local.image
}

output "ec2_instance_id" {
  value = one(module.ec2[*].instance_id)
}

output "ec2_public_ip" {
  value = one(module.ec2[*].public_ip)
}

output "fargate_service" {
  value = one(module.fargate[*].service_name)
}
