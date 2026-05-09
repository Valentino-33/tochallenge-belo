output "node_role_arn" {
  value = aws_iam_role.node.arn
}

output "node_role_name" {
  value = aws_iam_role.node.name
}

output "stateless_node_group_arn" {
  value = aws_eks_node_group.stateless.arn
}

output "statefull_node_group_arn" {
  value = aws_eks_node_group.statefull.arn
}

output "statefull_ebs_volume_id" {
  value = aws_ebs_volume.statefull.id
}
