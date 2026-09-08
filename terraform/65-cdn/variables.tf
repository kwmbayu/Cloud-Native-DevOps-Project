variable "project_name" {
  default = "expense"
}

variable "environment" {
  default = "dev"
}

variable "zone_name" {
  default = "kwmbayu.com"
}

variable "zone_id" {
  # Route 53 hosted zone for kwmbayu.com
  default = "Z01342433HV3BZ4DNL5IX"
}

variable "common_tags" {
  default = {
    Project     = "expense"
    Environment = "dev"
    Terraform   = "true"
    Owner       = "kwmbayu"
    CostCenter  = "cloud-native-devops"
    Component   = "cdn"
  }
}
