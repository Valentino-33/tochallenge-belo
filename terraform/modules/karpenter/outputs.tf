output "controller_role_arn" {
  description = "ARN del rol que se anota en la SA `karpenter` del namespace `karpenter`."
  value       = aws_iam_role.controller.arn
}

output "node_role_name" {
  description = "Nombre del rol IAM que Karpenter le asigna a los nodos que lanza."
  value       = aws_iam_role.node.name
}

output "node_role_arn" {
  value = aws_iam_role.node.arn
}

output "interruption_queue_name" {
  value = aws_sqs_queue.karpenter_interruption.name
}
