terraform {
  required_version = ">= 1.6"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.50"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }

  # El backend S3 se inicializa via -backend-config en CLI, lo hace `make tf-init`.
  # Eso permite tener un solo archivo y reutilizarlo entre envs (test, staging, prod).
  backend "s3" {}
}

provider "aws" {
  region = var.region

  default_tags {
    tags = local.common_tags
  }
}
