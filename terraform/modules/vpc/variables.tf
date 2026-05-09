variable "name" {
  description = "Prefijo para todos los recursos de la VPC."
  type        = string
}

variable "cidr_block" {
  description = "CIDR de la VPC."
  type        = string
  default     = "10.0.0.0/16"
}

variable "azs" {
  description = "Availability Zones a usar (mínimo 2 para HA)."
  type        = list(string)
  validation {
    condition     = length(var.azs) >= 2
    error_message = "Necesitás al menos 2 AZs para alta disponibilidad."
  }
}

variable "public_subnet_cidrs" {
  description = "CIDRs de las subnets públicas. Una por AZ."
  type        = list(string)
}

variable "private_subnet_cidrs" {
  description = "CIDRs de las subnets privadas. Una por AZ."
  type        = list(string)
}

variable "cluster_name" {
  description = "Nombre del cluster EKS — usado para tags de discovery (Karpenter, ALB Controller)."
  type        = string
}

variable "tags" {
  description = "Tags comunes."
  type        = map(string)
  default     = {}
}
