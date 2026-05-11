data "aws_caller_identity" "current" {}

locals {
  common_tags = {
    project     = "tochallenge-belo"
    environment = "staging"
    managed_by  = "terraform"
    cluster     = var.cluster_name
    owner       = var.dockerhub_user
  }
}

# ──────────────── VPC ────────────────

module "vpc" {
  source = "../../modules/vpc"

  name                 = var.cluster_name
  cluster_name         = var.cluster_name
  cidr_block           = var.vpc_cidr
  azs                  = var.azs
  public_subnet_cidrs  = var.public_subnet_cidrs
  private_subnet_cidrs = var.private_subnet_cidrs
  tags                 = local.common_tags
}

# ──────────────── EKS Cluster ────────────────

module "eks" {
  source = "../../modules/eks"

  cluster_name                  = var.cluster_name
  kubernetes_version            = var.kubernetes_version
  vpc_id                        = module.vpc.vpc_id
  subnet_ids                    = concat(module.vpc.public_subnet_ids, module.vpc.private_subnet_ids)
  endpoint_public_access        = true
  endpoint_public_access_cidrs  = var.endpoint_public_access_cidrs
  tags                          = local.common_tags
}

# ──────────────── Node Groups ────────────────

module "eks_nodes" {
  source = "../../modules/eks-nodes"

  cluster_name                       = module.eks.cluster_name
  cluster_version                    = module.eks.cluster_version
  cluster_endpoint                   = module.eks.cluster_endpoint
  cluster_certificate_authority_data = module.eks.cluster_certificate_authority_data
  cluster_security_group_id          = module.eks.cluster_security_group_id

  private_subnet_ids   = module.vpc.private_subnet_ids
  stateless_subnet_ids = module.vpc.private_subnet_ids
  statefull_subnet_id  = module.vpc.private_subnet_ids[0]
  statefull_az         = var.azs[0]

  ami_id       = var.ami_id
  ssh_key_name = var.ssh_key_name
  tags         = local.common_tags
}

# ──────────────── Karpenter (IAM + SQS) ────────────────

module "karpenter" {
  source = "../../modules/karpenter"

  cluster_name      = module.eks.cluster_name
  oidc_provider_arn = module.eks.oidc_provider_arn
  oidc_provider_url = module.eks.oidc_provider_url
  tags              = local.common_tags
}

# ──────────────── ALB Controller IRSA ────────────────

module "alb_controller_irsa" {
  source = "../../modules/alb-controller-irsa"

  cluster_name      = module.eks.cluster_name
  oidc_provider_arn = module.eks.oidc_provider_arn
  oidc_provider_url = module.eks.oidc_provider_url
  policy_file_path  = "${path.module}/../../modules/alb-controller-irsa/iam_policy.json"
  tags              = local.common_tags
}
