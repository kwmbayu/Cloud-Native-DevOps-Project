resource "aws_ssm_parameter" "db_sg_id" {
  name  = "/${var.project_name}/${var.environment}/db_sg_id"
  type  = "String"
  value = aws_security_group.db.id
}

resource "aws_ssm_parameter" "bastion_sg_id" {
  name  = "/${var.project_name}/${var.environment}/bastion_sg_id"
  type  = "String"
  value = aws_security_group.bastion.id
}

resource "aws_ssm_parameter" "vpn_sg_id" {
  name  = "/${var.project_name}/${var.environment}/vpn_sg_id"
  type  = "String"
  value = aws_security_group.vpn.id
}

resource "aws_ssm_parameter" "cluster_sg_id" {
  name  = "/${var.project_name}/${var.environment}/cluster_sg_id"
  type  = "String"
  value = aws_security_group.cluster.id
}

resource "aws_ssm_parameter" "node_sg_id" {
  name  = "/${var.project_name}/${var.environment}/node_sg_id"
  type  = "String"
  value = aws_security_group.node.id
}

resource "aws_ssm_parameter" "ingress_sg_id" {
  name  = "/${var.project_name}/${var.environment}/ingress_sg_id"
  type  = "String"
  value = aws_security_group.ingress.id
}
