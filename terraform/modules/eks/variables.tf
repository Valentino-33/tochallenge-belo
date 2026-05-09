variable "cluster_name" {
  type = string
}

variable "kubernetes_version" {
  type    = string
  default = "1.30"
}

variable "vpc_id" {
  type = string
}

variable "subnet_ids" {
  description = "Subnets donde se levanta el control plane (ENIs). Mezcla de pública y privada."
  type        = list(string)
}

variable "endpoint_public_access" {
  description = "Si true, la API del cluster es accesible desde internet. Para demo conviene true; para prod, false + bastion."
  type        = bool
  default     = true
}

variable "endpoint_public_access_cidrs" {
  description = "CIDRs autorizados a hablar con la API pública. 0.0.0.0/0 abre a todo internet."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "tags" {
  type    = map(string)
  default = {}
}
