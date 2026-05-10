data "aws_ssm_parameter" "eks_ami_id" {
  name = "/aws/service/eks/optimized-ami/${var.cluster_version}/amazon-linux-2023/x86_64/standard/recommended/image_id"
}

# ──────────────── Launch template del nodo statefull ────────────────
# Necesita launch template custom para inyectar el script de bootstrap del EBS.

resource "aws_launch_template" "statefull" {
  name_prefix = "${var.cluster_name}-statefull-"
  image_id    = data.aws_ssm_parameter.eks_ami_id.value

  key_name = var.ssh_key_name

  user_data = base64encode(templatefile(
    "${path.module}/templates/statefull-bootstrap.sh.tpl",
    {
      cluster_name = var.cluster_name
      ebs_size_gb  = var.statefull_ebs_size_gb
    }
  ))

  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      volume_size = 20
      volume_type = "gp3"
      encrypted   = true
    }
  }

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 2  # 2 para que las pods con IRSA puedan leer metadata
  }

  tag_specifications {
    resource_type = "instance"
    tags = merge(var.tags, {
      Name = "${var.cluster_name}-statefull-node"
      role = "statefulls"
    })
  }

  lifecycle {
    create_before_destroy = true
  }
}

# ──────────────── Node group statefulls ────────────────

resource "aws_eks_node_group" "statefull" {
  cluster_name    = var.cluster_name
  node_group_name = "statefulls"
  node_role_arn   = aws_iam_role.node.arn
  subnet_ids      = [var.statefull_subnet_id]   # pinneado a una sola AZ por el EBS zonal

  instance_types = var.statefull_instance_types

  scaling_config {
    desired_size = 1
    max_size     = 1
    min_size     = 1
  }

  update_config {
    max_unavailable = 1
  }

  launch_template {
    id      = aws_launch_template.statefull.id
    version = aws_launch_template.statefull.latest_version
  }

  labels = {
    role     = "statefulls"
    workload = "statefulls"
  }

  taint {
    key    = "workload"
    value  = "statefulls"
    effect = "NO_SCHEDULE"
  }

  tags = merge(var.tags, {
    Name = "${var.cluster_name}-ng-statefulls"
  })

  depends_on = [
    aws_iam_role_policy_attachment.AmazonEKSWorkerNodePolicy,
    aws_iam_role_policy_attachment.AmazonEKS_CNI_Policy,
    aws_iam_role_policy_attachment.AmazonEC2ContainerRegistryReadOnly,
    aws_iam_role_policy.node_ebs_self_attach,
  ]
}

# ──────────────── Node group stateless ────────────────

resource "aws_eks_node_group" "stateless" {
  cluster_name    = var.cluster_name
  node_group_name = "stateless"
  node_role_arn   = aws_iam_role.node.arn
  subnet_ids      = var.stateless_subnet_ids

  instance_types = var.stateless_instance_types
  ami_type       = "AL2023_x86_64_STANDARD"
  capacity_type  = "ON_DEMAND"   # cambiar a SPOT más adelante si se desea bajar costo

  scaling_config {
    desired_size = var.stateless_desired_size
    max_size     = var.stateless_max_size
    min_size     = var.stateless_min_size
  }

  update_config {
    max_unavailable = 1
  }

  labels = {
    role     = "stateless"
    workload = "stateless"
  }

  tags = merge(var.tags, {
    Name = "${var.cluster_name}-ng-stateless"
  })

  depends_on = [
    aws_iam_role_policy_attachment.AmazonEKSWorkerNodePolicy,
    aws_iam_role_policy_attachment.AmazonEKS_CNI_Policy,
    aws_iam_role_policy_attachment.AmazonEC2ContainerRegistryReadOnly,
  ]
}
