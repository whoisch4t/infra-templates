# The default VPC keeps this free of NAT gateways and extra subnets.
# For anything long-lived, use a dedicated VPC with private subnets.
data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
  filter {
    name   = "default-for-az"
    values = ["true"]
  }
}

module "ecr" {
  source = "../../modules/ecr"
  name   = var.name
}

locals {
  image = "${module.ecr.repository_url}:${var.image_tag}"
}

module "ec2" {
  count  = var.compute == "ec2" ? 1 : 0
  source = "../../modules/ec2-app"

  name               = var.name
  image              = local.image
  ecr_repository_arn = module.ecr.repository_arn
  vpc_id             = data.aws_vpc.default.id
  subnet_id          = sort(data.aws_subnets.default.ids)[0]
  allowed_cidrs      = var.allowed_cidrs
}

module "fargate" {
  count  = var.compute == "fargate" ? 1 : 0
  source = "../../modules/ecs-fargate"

  name          = var.name
  image         = local.image
  vpc_id        = data.aws_vpc.default.id
  subnet_ids    = data.aws_subnets.default.ids
  allowed_cidrs = var.allowed_cidrs
  use_spot      = var.fargate_use_spot
  environment = {
    SHUTDOWN_DELAY = "5s"
  }
}
