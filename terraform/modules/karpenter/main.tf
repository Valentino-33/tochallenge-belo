# Karpenter usa una cola SQS para recibir notificaciones de:
# - Spot interruption (avisa 2 min antes de bajar la instancia)
# - Health events de EC2
# - Cambios de estado de instancias
# Sin esta cola, Karpenter sigue funcionando, pero no maneja gracefully las
# interrupciones de Spot — los pods se mueren de golpe en vez de drainearse.

resource "aws_sqs_queue" "karpenter_interruption" {
  name                      = "${var.cluster_name}-karpenter"
  message_retention_seconds = 300
  sqs_managed_sse_enabled   = true

  tags = var.tags
}

data "aws_iam_policy_document" "karpenter_sqs" {
  statement {
    effect    = "Allow"
    actions   = ["sqs:SendMessage"]
    resources = [aws_sqs_queue.karpenter_interruption.arn]
    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com", "sqs.amazonaws.com"]
    }
  }
}

resource "aws_sqs_queue_policy" "karpenter_interruption" {
  queue_url = aws_sqs_queue.karpenter_interruption.id
  policy    = data.aws_iam_policy_document.karpenter_sqs.json
}

# ──────────────── Reglas de EventBridge que pushean a SQS ────────────────

resource "aws_cloudwatch_event_rule" "karpenter_spot" {
  name        = "${var.cluster_name}-karpenter-spot-int"
  description = "Spot interruption warnings → Karpenter"
  event_pattern = jsonencode({
    source      = ["aws.ec2"]
    detail-type = ["EC2 Spot Instance Interruption Warning"]
  })
  tags = var.tags
}

resource "aws_cloudwatch_event_target" "karpenter_spot" {
  rule = aws_cloudwatch_event_rule.karpenter_spot.name
  arn  = aws_sqs_queue.karpenter_interruption.arn
}

resource "aws_cloudwatch_event_rule" "karpenter_rebalance" {
  name        = "${var.cluster_name}-karpenter-rebalance"
  description = "EC2 instance rebalance recommendations → Karpenter"
  event_pattern = jsonencode({
    source      = ["aws.ec2"]
    detail-type = ["EC2 Instance Rebalance Recommendation"]
  })
  tags = var.tags
}

resource "aws_cloudwatch_event_target" "karpenter_rebalance" {
  rule = aws_cloudwatch_event_rule.karpenter_rebalance.name
  arn  = aws_sqs_queue.karpenter_interruption.arn
}

resource "aws_cloudwatch_event_rule" "karpenter_state_change" {
  name        = "${var.cluster_name}-karpenter-state-change"
  description = "EC2 instance state changes → Karpenter"
  event_pattern = jsonencode({
    source      = ["aws.ec2"]
    detail-type = ["EC2 Instance State-change Notification"]
  })
  tags = var.tags
}

resource "aws_cloudwatch_event_target" "karpenter_state_change" {
  rule = aws_cloudwatch_event_rule.karpenter_state_change.name
  arn  = aws_sqs_queue.karpenter_interruption.arn
}
