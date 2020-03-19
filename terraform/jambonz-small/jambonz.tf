# Create feature server instance
# select the most recent jambonz AMIs
data "aws_ami" "jambonz-feature-server" {
  most_recent      = true
  name_regex       = "^jambonz-feature-server"
  owners           = ["376029039784"]
}

# create an elastic IP and copy google credentials into place
resource "aws_eip" "jambonz-feature-server" {
  count          = length(var.jambonz_feature_server_private_ips)

  instance = aws_instance.jambonz-feature-server[count.index].id
  vpc      = true

  # copy user-provided google application credentials file
  provisioner "file" {
    source      = "credentials/"
    destination = "/home/admin/credentials"

    connection {
      type      = "ssh"
      user      = "admin"
      host      = self.public_ip
    }
  }
}

# create the jambonz feature server instance
resource "aws_instance" "jambonz-feature-server" {
  count          = length(var.jambonz_feature_server_private_ips)

  ami                    = data.aws_ami.jambonz-feature-server.id
  instance_type          = var.ec2_instance_type
  private_ip             = var.jambonz_feature_server_private_ips[count.index]
  subnet_id              = local.my_subnet_ids[count.index]
  vpc_security_group_ids = [aws_security_group.allow_jambonz_feature_server.id]
  user_data              = templatefile("${path.module}/feature-server.ecosystem.config.js.tmpl", {
    VPC_CIDR                = var.vpc_cidr_block
    JAMBONES_SBC_SIP_IPS    = join(",", var.jambonz_sbc_sip_rtp_private_ips)
    JAMBONES_MYSQL_HOST     = aws_rds_cluster.jambonz.endpoint
    JAMBONES_MYSQL_USER     = aws_rds_cluster.jambonz.master_username
    JAMBONES_MYSQL_PASSWORD = aws_rds_cluster.jambonz.master_password
    JAMBONES_REDIS_HOST     = aws_elasticache_cluster.jambonz.cache_nodes.0.address
    AWS_ACCESS_KEY_ID       = var.aws_access_key_id_runtime
    AWS_SECRET_ACCESS_KEY   = var.aws_secret_access_key_runtime
    AWS_REGION              = var.region
  })
  key_name               = var.key_name
  monitoring             = true

  depends_on = [aws_internet_gateway.jambonz, aws_elasticache_cluster.jambonz, aws_rds_cluster.jambonz]

  tags = {
    Name = "jambonz-feature-server"  
  }
}

# Create SBC SIP+RTP instance
data "aws_ami" "jambonz-sbc-sip-rtp" {
  most_recent      = true
  name_regex       = "^jambonz-sbc-sip-rtp"
  owners           = ["376029039784"]
}
resource "aws_eip" "jambonz-sbc-sip-rtp" {
  count          = length(var.jambonz_sbc_sip_rtp_private_ips)

  instance = aws_instance.jambonz-sbc-sip-rtp-server[count.index].id
  vpc      = true
}
resource "aws_instance" "jambonz-sbc-sip-rtp-server" {
  count          = length(var.jambonz_sbc_sip_rtp_private_ips)

  ami                    = data.aws_ami.jambonz-sbc-sip-rtp.id
  instance_type          = var.ec2_instance_type
  private_ip             = var.jambonz_sbc_sip_rtp_private_ips[count.index]
  subnet_id              = local.my_subnet_ids[count.index]
  vpc_security_group_ids = [aws_security_group.allow_jambonz_sbc_sip_rtp.id]
  user_data              = templatefile("${path.module}/sbc-sip-rtp-server.ecosystem.config.js.tmpl", {
    VPC_CIDR                = var.vpc_cidr_block
    JAMBONES_FEATURE_SERVER_FOR_API_CALLS = var.jambonz_feature_server_private_ips[0]
    JAMBONES_FEATURE_SERVER_IPS = join(",", var.jambonz_feature_server_private_ips)
    JAMBONES_SBC_SIP_IPS    = join(",", var.jambonz_sbc_sip_rtp_private_ips)
    JAMBONES_RTPENGINE_IPS  = join(",", local.rtpengine_hostports)
    JAMBONES_MYSQL_HOST     = aws_rds_cluster.jambonz.endpoint
    JAMBONES_MYSQL_USER     = aws_rds_cluster.jambonz.master_username
    JAMBONES_MYSQL_PASSWORD = aws_rds_cluster.jambonz.master_password
    JAMBONES_REDIS_HOST     = aws_elasticache_cluster.jambonz.cache_nodes.0.address
  })
  key_name               = var.key_name
  monitoring             = true

  depends_on = [aws_internet_gateway.jambonz, aws_elasticache_cluster.jambonz, aws_rds_cluster.jambonz]

  tags = {
    Name = "jambonz-sbc-sip-rtp-server"  
  }
}


# seed the database, from one of the feature servers
resource "null_resource" "seed" {

  # Bootstrap script can run on any instance of the cluster
  # So we just choose the first in this case
  connection {
    type      = "ssh"
    user      = "admin"
    host      = element(aws_eip.jambonz-sbc-sip-rtp.*.public_ip, 0)
  }

  provisioner "remote-exec" {
    inline = [
      "mysql -h ${aws_rds_cluster.jambonz.endpoint} -u admin -D jambones -pJambonzR0ck$ < /home/admin/apps/jambonz-api-server/db/jambones-sql.sql",
      "mysql -h ${aws_rds_cluster.jambonz.endpoint} -u admin -D jambones -pJambonzR0ck$ < /home/admin/apps/jambonz-api-server/db/create-admin-token.sql",
    ]
  }

  depends_on = [aws_rds_cluster.jambonz, aws_instance.jambonz-sbc-sip-rtp-server]
}
