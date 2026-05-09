variable "cluster_name" {
  type = string
}

variable "cluster_version" {
  type = string
}

variable "cluster_endpoint" {
  type = string
}

variable "cluster_certificate_authority_data" {
  type = string
}

variable "cluster_security_group_id" {
  type        = string
  description = "SG del control plane, para autorizar el tráfico nodo→API."
}

variable "private_subnet_ids" {
  description = "Subnets privadas donde se levantan los nodos."
  type        = list(string)
}

variable "stateless_subnet_ids" {
  description = "Subnets para el node group stateless (puede usar todas las AZs)."
  type        = list(string)
}

variable "statefull_subnet_id" {
  description = "Subnet pinneada del nodo statefull. Una sola, porque el EBS es zonal."
  type        = string
}

variable "statefull_az" {
  description = "AZ donde vive el nodo statefull y su EBS."
  type        = string
}

variable "stateless_instance_types" {
  type    = list(string)
  default = ["t3.medium"]
}

variable "statefull_instance_types" {
  type    = list(string)
  default = ["t3.large"]
}

variable "stateless_desired_size" {
  type    = number
  default = 2
}

variable "stateless_min_size" {
  type    = number
  default = 2
}

variable "stateless_max_size" {
  type    = number
  default = 4
}

variable "statefull_ebs_size_gb" {
  type    = number
  default = 20
}

variable "ssh_key_name" {
  description = "Optional. Si se setea, los nodos quedan accesibles por SSH (usar SSM Session Manager mejor)."
  type        = string
  default     = null
}

variable "tags" {
  type    = map(string)
  default = {}
}
