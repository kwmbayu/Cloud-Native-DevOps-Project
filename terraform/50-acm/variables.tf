variable "project_name" {
  default = "expense"
}

variable "environment" {
  default = "dev"
}

variable "common_tags" {
  default = {
    Project = "expense"
    Environment = "dev"
    Terraform = "true"
    Component = "ingress-alb"
  }
}

variable "zone_name" {
  default = "kwmbayu.com"
}

variable "zone_id" {
  # Route 53 hosted zone created automatically when kwmbayu.com was registered
  default = "Z01342433HV3BZ4DNL5IX"
}