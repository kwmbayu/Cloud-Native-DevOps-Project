# BASTION HOST DISABLED — replaced by AWS Systems Manager Session Manager.
#
# Why: The Bastion EC2 required SSH port 22 open to the internet (0.0.0.0/0),
# which is a security risk. SSM Session Manager provides the same shell access
# with zero open ports — all traffic goes over HTTPS through AWS's network.
#
# How to connect to EKS nodes using SSM (no SSH needed):
#   1. Install Session Manager plugin:
#      brew install --cask session-manager-plugin
#   2. Connect to a node:
#      aws ssm start-session --target <ec2-instance-id>
#   3. Port-forward to RDS for DB admin:
#      aws ssm start-session --target <ec2-instance-id> \
#        --document-name AWS-StartPortForwardingSessionToRemoteHost \
#        --parameters '{"host":["<rds-endpoint>"],"portNumber":["3306"],"localPortNumber":["3306"]}'
#
# To re-enable the Bastion (not recommended), uncomment the block below:
#
# module "bastion" {
#   source  = "terraform-aws-modules/ec2-instance/aws"
#   version = "~> 6.0"
#   name = "${var.project_name}-${var.environment}-bastion"
#   instance_type          = "t3.micro"
#   vpc_security_group_ids = [data.aws_ssm_parameter.bastion_sg_id.value]
#   subnet_id = local.public_subnet_id
#   ami = data.aws_ami.ami_info.id
#   user_data = file("bastion.sh")
#   tags = merge(var.common_tags, { Name = "${var.project_name}-${var.environment}-bastion" })
# }