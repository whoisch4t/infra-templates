terraform {
  required_version = ">= 1.11"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

locals {
  # Free-tier-eligible types. Check what your account's free plan covers before relying on this list.
  free_tier_types = ["t2.micro", "t3.micro", "t3.small", "t4g.micro", "t4g.small"]
  registry        = split("/", var.image)[0]
}

check "free_tier_instance" {
  assert {
    condition     = var.allow_paid_instance_type || contains(local.free_tier_types, var.instance_type)
    error_message = "${var.instance_type} is not free-tier eligible. Set allow_paid_instance_type = true if that's intended."
  }
}

data "aws_region" "current" {}

# Latest Amazon Linux 2023, looked up from AWS's public SSM parameter.
data "aws_ssm_parameter" "al2023" {
  name = startswith(var.instance_type, "t4g") ? "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-arm64" : "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

data "aws_iam_policy_document" "ec2_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "this" {
  name               = "${var.name}-instance"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
}

# Shell access through SSM Session Manager: no SSH key, no port 22.
resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.this.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

data "aws_iam_policy_document" "pull" {
  statement {
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }
  statement {
    actions   = ["ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer", "ecr:BatchCheckLayerAvailability"]
    resources = [var.ecr_repository_arn]
  }
}

resource "aws_iam_role_policy" "pull" {
  name   = "ecr-pull"
  role   = aws_iam_role.this.id
  policy = data.aws_iam_policy_document.pull.json
}

resource "aws_iam_instance_profile" "this" {
  name = "${var.name}-instance"
  role = aws_iam_role.this.name
}

resource "aws_security_group" "this" {
  name        = "${var.name}-instance"
  description = "${var.name} instance"
  vpc_id      = var.vpc_id
}

resource "aws_vpc_security_group_ingress_rule" "http" {
  for_each          = toset(var.allowed_cidrs)
  security_group_id = aws_security_group.this.id
  description       = "HTTP"
  cidr_ipv4         = each.value
  from_port         = 80
  to_port           = 80
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "https" {
  security_group_id = aws_security_group.this.id
  description       = "HTTPS for ECR, SSM and package updates"
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
}

resource "aws_instance" "this" {
  ami                         = data.aws_ssm_parameter.al2023.value
  instance_type               = var.instance_type
  subnet_id                   = var.subnet_id
  vpc_security_group_ids      = [aws_security_group.this.id]
  iam_instance_profile        = aws_iam_instance_profile.this.name
  associate_public_ip_address = true
  monitoring                  = false # detailed monitoring is billed

  # t3/t4g default to "unlimited", which bills for CPU bursts beyond the credits. Standard just throttles.
  credit_specification {
    cpu_credits = "standard"
  }

  metadata_options {
    http_tokens                 = "required" # IMDSv2 only
    http_put_response_hop_limit = 1          # containers can't reach the instance credentials
  }

  root_block_device {
    volume_type           = "gp3"
    volume_size           = var.root_volume_gb
    encrypted             = true
    delete_on_termination = true
  }

  user_data = templatefile("${path.module}/user-data.sh.tftpl", {
    region         = data.aws_region.current.region
    registry       = local.registry
    image          = var.image
    container_port = var.container_port
  })
  # A new image tag means new user data, which replaces the instance: simple and repeatable.
  user_data_replace_on_change = true

  tags = {
    Name = var.name
  }

  lifecycle {
    ignore_changes = [ami] # don't replace the instance every time AWS publishes a new AMI
  }
}
