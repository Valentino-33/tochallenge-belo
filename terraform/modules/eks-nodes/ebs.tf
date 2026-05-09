# EBS gp3 de 20GB que se attachea al nodo statefull en cada bootstrap.
# El script de user_data se encarga de buscar este volume por tag y atacharlo.
# Si el nodo se reemplaza (autoscaling, upgrade), el nuevo nodo levanta y vuelve
# a atachar el mismo EBS — los datos persisten.

resource "aws_ebs_volume" "statefull" {
  availability_zone = var.statefull_az
  size              = var.statefull_ebs_size_gb
  type              = "gp3"
  encrypted         = true

  # Esta flag previene que un `terraform destroy` se lleve los datos por delante.
  # Para destruir realmente, hay que hacer dos pasos:
  # 1. Comentar este lifecycle block, terraform apply
  # 2. terraform destroy
  lifecycle {
    prevent_destroy = false
  }

  tags = merge(var.tags, {
    Name                              = "${var.cluster_name}-statefull-data"
    "${var.cluster_name}-statefull"   = "true"  # <- el script lo busca por este tag
    "k8s.io/cluster-autoscaler/${var.cluster_name}" = "owned"
  })
}
