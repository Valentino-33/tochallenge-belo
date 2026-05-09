output "cluster_name" {
  value = module.eks.cluster_name
}

output "cluster_endpoint" {
  value = module.eks.cluster_endpoint
}

output "cluster_version" {
  value = module.eks.cluster_version
}

output "region" {
  value = var.region
}

output "vpc_id" {
  value = module.vpc.vpc_id
}

output "public_subnet_ids" {
  value = module.vpc.public_subnet_ids
}

output "private_subnet_ids" {
  value = module.vpc.private_subnet_ids
}

output "oidc_provider_arn" {
  value = module.eks.oidc_provider_arn
}

# IRSA roles que se anotan en las service accounts cuando se instalen los addons
# en la Fase 3.
output "karpenter_controller_role_arn" {
  value = module.karpenter.controller_role_arn
}

output "karpenter_node_role_name" {
  value = module.karpenter.node_role_name
}

output "karpenter_interruption_queue" {
  value = module.karpenter.interruption_queue_name
}

output "alb_controller_role_arn" {
  value = module.alb_controller_irsa.role_arn
}

# Comando listo para copiar/pegar y configurar kubectl.
output "kubeconfig_cmd" {
  value = "aws eks update-kubeconfig --name ${module.eks.cluster_name} --region ${var.region} --alias ${module.eks.cluster_name}"
}

output "account_id" {
  value = data.aws_caller_identity.current.account_id
}
