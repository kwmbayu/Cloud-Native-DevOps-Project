variable "project_name" {
    default = "expense"
}

variable "environment" {
  default = "dev"
}

variable "common_tags" {
  default = {
    Project     = "expense"
    Environment = "dev"
    Terraform   = "true"
    Owner       = "kwmbayu"      # who to contact when something in this layer breaks
    CostCenter  = "cloud-native-devops"  # links AWS costs to this project in billing reports
  }
}

variable "public_subnet_cidrs" {
    default = ["10.0.1.0/24","10.0.2.0/24"]
}

variable "private_subnet_cidrs" {
    default = ["10.0.11.0/24","10.0.12.0/24"]
}

variable "database_subnet_cidrs" {
    default = ["10.0.21.0/24","10.0.22.0/24"]
}

variable "is_peering_required" {
  default = true
}