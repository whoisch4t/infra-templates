terraform {
  required_version = ">= 1.11" # use_lockfile for the S3 backend

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }

  # Remote state in the bucket from terraform/bootstrap. Bucket and region come from backend.hcl:
  #   terraform init -backend-config=backend.hcl
  backend "s3" {
    key          = "infra-templates/demo/terraform.tfstate"
    encrypt      = true
    use_lockfile = true # S3-native lock, no DynamoDB table
  }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project     = "infra-templates"
      Environment = "demo"
      ManagedBy   = "terraform"
    }
  }
}
