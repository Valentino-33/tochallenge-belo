data "aws_ami" "eks_ubuntu" {
  count       = var.ami_id == null ? 1 : 0
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu-eks/k8s_${var.cluster_version}/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
  }

  filter {
    name   = "state"
    values = ["available"]
  }

  filter {
    name   = "architecture"
    values = ["x86_64"]
  }
}

locals {
  eks_ami_id = var.ami_id != null ? var.ami_id : data.aws_ami.eks_ubuntu[0].id
}

# ──────────────── Launch template del nodo statefull ────────────────
# Necesita launch template custom para inyectar el script de bootstrap del EBS.

resource "aws_launch_template" "statefull" {
  name_prefix = "${var.cluster_name}-statefull-"
  image_id    = local.eks_ami_id

  key_name = var.ssh_key_name

  user_data = base64encode(templatefile(
    "${path.module}/templates/statefull-bootstrap.sh.tpl",
    {
      cluster_name     = var.cluster_name
      ebs_size_gb      = var.statefull_ebs_size_gb
      cluster_endpoint = var.cluster_endpoint
      cluster_ca       = var.cluster_certificate_authority_data
    }
  ))

  block_device_mappings {
    device_name = "/dev/sda1"  # Ubuntu usa sda1 como root device (no xvda)
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

# ──────────────── Launch templates de nodos stateless y cicd ────────────────
# Necesitamos custom LT para CUSTOM ami_type (Ubuntu). Solo AMI + bootstrap;
# instance_types e scaling siguen declarados en el node group.

resource "aws_launch_template" "stateless" {
  name_prefix = "${var.cluster_name}-stateless-"
  image_id    = local.eks_ami_id

  user_data = base64encode(templatefile(
    "${path.module}/templates/node-bootstrap.sh.tpl",
    {
      cluster_name     = var.cluster_name
      cluster_endpoint = var.cluster_endpoint
      cluster_ca       = var.cluster_certificate_authority_data
    }
  ))

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
  }

  tag_specifications {
    resource_type = "instance"
    tags = merge(var.tags, {
      Name = "${var.cluster_name}-stateless-node"
      role = "stateless"
    })
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_launch_template" "cicd" {
  name_prefix = "${var.cluster_name}-cicd-"
  image_id    = local.eks_ami_id

  user_data = base64encode(templatefile(
    "${path.module}/templates/node-bootstrap.sh.tpl",
    {
      cluster_name     = var.cluster_name
      cluster_endpoint = var.cluster_endpoint
      cluster_ca       = var.cluster_certificate_authority_data
    }
  ))

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
  }

  tag_specifications {
    resource_type = "instance"
    tags = merge(var.tags, {
      Name = "${var.cluster_name}-cicd-node"
      role = "cicd"
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
  ami_type       = "CUSTOM"

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
    aws_ebs_volume.statefull,
  ]
}

# ──────────────── Node group stateless ────────────────

resource "aws_eks_node_group" "stateless" {
  cluster_name    = var.cluster_name
  node_group_name = "stateless"
  node_role_arn   = aws_iam_role.node.arn
  subnet_ids      = var.stateless_subnet_ids

  instance_types = var.stateless_instance_types
  ami_type       = "CUSTOM"
  capacity_type  = "ON_DEMAND"   # cambiar a SPOT más adelante si se desea bajar costo

  launch_template {
    id      = aws_launch_template.stateless.id
    version = aws_launch_template.stateless.latest_version
  }

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

# ──────────────── Node group cicd ────────────────
# Nodo dedicado exclusivamente a Tekton Pipelines y sus tasks de build.
# - Taint workload=cicd:NoSchedule para que solo pods de Tekton aterricen acá.
# - PVCs efímeros de hasta 1 GiB por PipelineRun, provistos por gp3 dinámico.
# - Acceso a internet vía NAT para clonar repos, bajar dependencias y pushear imágenes.

resource "aws_eks_node_group" "cicd" {
  cluster_name    = var.cluster_name
  node_group_name = "cicd"
  node_role_arn   = aws_iam_role.node.arn
  subnet_ids      = [var.stateless_subnet_ids[0]]   # una sola AZ suficiente — si cae, los pipelines se encolan

  instance_types = var.cicd_instance_types
  ami_type       = "CUSTOM"
  capacity_type  = "ON_DEMAND"

  launch_template {
    id      = aws_launch_template.cicd.id
    version = aws_launch_template.cicd.latest_version
  }

  scaling_config {
    desired_size = 1
    max_size     = 1
    min_size     = 1
  }

  update_config {
    max_unavailable = 1
  }

  labels = {
    role     = "cicd"
    workload = "cicd"
  }

  taint {
    key    = "workload"
    value  = "cicd"
    effect = "NO_SCHEDULE"
  }

  tags = merge(var.tags, {
    Name = "${var.cluster_name}-ng-cicd"
  })

  depends_on = [
    aws_iam_role_policy_attachment.AmazonEKSWorkerNodePolicy,
    aws_iam_role_policy_attachment.AmazonEKS_CNI_Policy,
    aws_iam_role_policy_attachment.AmazonEC2ContainerRegistryReadOnly,
    aws_iam_role_policy_attachment.AmazonSSMManagedInstanceCore,
  ]
}
