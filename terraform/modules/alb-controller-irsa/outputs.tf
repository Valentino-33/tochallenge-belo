output "role_arn" {
  description = "ARN del rol que se anota en la SA `aws-load-balancer-controller` del namespace `kube-system`."
  value       = aws_iam_role.alb_controller.arn
}
