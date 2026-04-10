data "aws_availability_zones" "available" {
  state = "available"
}

data "aws_ami" "al2023" {
  owners      = ["amazon"]
  most_recent = true

  filter {
    name   = "name"
    values = ["al2023-ami-*-x86_64"]
  }
}

resource "random_password" "db" {
  length           = 24
  special          = true
  override_special = "!#$%&*()-_=+[]{}<>:?"
}

locals {
  name = "${var.project_name}-${var.environment}"

  common_tags = merge(
    var.tags,
    {
      Environment = var.environment
      Stack       = local.name
    }
  )

  db_name = replace(var.environment, "-", "")

  db_port = var.db_engine == "postgres" ? 5432 : 3306

  db_family = var.db_engine == "postgres" ? "postgres15" : "mysql8.0"

  db_engine_version = var.db_engine == "postgres" ? "15.8" : "8.0.39"

  db_instance_class = "db.t3.micro"
}

resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = merge(local.common_tags, { Name = "${local.name}-vpc" })
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id

  tags = merge(local.common_tags, { Name = "${local.name}-igw" })
}

resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.this.id
  cidr_block              = var.public_subnet_cidr
  availability_zone       = data.aws_availability_zones.available.names[0]
  map_public_ip_on_launch = true

  tags = merge(local.common_tags, { Name = "${local.name}-public-a" })
}

resource "aws_subnet" "app" {
  vpc_id            = aws_vpc.this.id
  cidr_block        = var.app_subnet_cidr
  availability_zone = data.aws_availability_zones.available.names[0]

  tags = merge(local.common_tags, { Name = "${local.name}-app-a" })
}

resource "aws_subnet" "db_a" {
  vpc_id            = aws_vpc.this.id
  cidr_block        = var.db_subnet_a_cidr
  availability_zone = data.aws_availability_zones.available.names[0]

  tags = merge(local.common_tags, { Name = "${local.name}-db-a" })
}

resource "aws_subnet" "db_b" {
  vpc_id            = aws_vpc.this.id
  cidr_block        = var.db_subnet_b_cidr
  availability_zone = data.aws_availability_zones.available.names[1]

  tags = merge(local.common_tags, { Name = "${local.name}-db-b" })
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id

  tags = merge(local.common_tags, { Name = "${local.name}-rt-public" })
}

resource "aws_route" "public_internet" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.this.id
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table" "app" {
  vpc_id = aws_vpc.this.id

  tags = merge(local.common_tags, { Name = "${local.name}-rt-app" })
}

resource "aws_route_table_association" "app" {
  subnet_id      = aws_subnet.app.id
  route_table_id = aws_route_table.app.id
}

resource "aws_route_table" "db" {
  vpc_id = aws_vpc.this.id

  tags = merge(local.common_tags, { Name = "${local.name}-rt-db" })
}

resource "aws_route_table_association" "db_a" {
  subnet_id      = aws_subnet.db_a.id
  route_table_id = aws_route_table.db.id
}

resource "aws_route_table_association" "db_b" {
  subnet_id      = aws_subnet.db_b.id
  route_table_id = aws_route_table.db.id
}

resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.this.id
  service_name      = "com.amazonaws.${var.aws_region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.app.id, aws_route_table.db.id]

  tags = merge(local.common_tags, { Name = "${local.name}-vpce-s3" })
}

resource "aws_security_group" "vpce" {
  name                   = "${local.name}-vpce-sg"
  description            = "Restrict VPC endpoints to app tier"
  vpc_id                 = aws_vpc.this.id
  revoke_rules_on_delete = true

  ingress {
    description     = "HTTPS from app tier"
    from_port       = 443
    to_port         = 443
    protocol        = "tcp"
    cidr_blocks     = [var.app_subnet_cidr]
  }

  egress {
    description = "No outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["127.0.0.1/32"]
  }

  tags = merge(local.common_tags, { Name = "${local.name}-vpce-sg" })
}

resource "aws_vpc_endpoint" "ssm" {
  vpc_id              = aws_vpc.this.id
  service_name        = "com.amazonaws.${var.aws_region}.ssm"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = [aws_subnet.app.id]
  private_dns_enabled = true
  security_group_ids  = [aws_security_group.vpce.id]

  tags = merge(local.common_tags, { Name = "${local.name}-vpce-ssm" })
}

resource "aws_vpc_endpoint" "ec2messages" {
  vpc_id              = aws_vpc.this.id
  service_name        = "com.amazonaws.${var.aws_region}.ec2messages"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = [aws_subnet.app.id]
  private_dns_enabled = true
  security_group_ids  = [aws_security_group.vpce.id]

  tags = merge(local.common_tags, { Name = "${local.name}-vpce-ec2messages" })
}

resource "aws_vpc_endpoint" "ssmmessages" {
  vpc_id              = aws_vpc.this.id
  service_name        = "com.amazonaws.${var.aws_region}.ssmmessages"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = [aws_subnet.app.id]
  private_dns_enabled = true
  security_group_ids  = [aws_security_group.vpce.id]

  tags = merge(local.common_tags, { Name = "${local.name}-vpce-ssmmessages" })
}

resource "aws_security_group" "public" {
  name                   = "${local.name}-public-sg"
  description            = "Public ingress for HTTPS only"
  vpc_id                 = aws_vpc.this.id
  revoke_rules_on_delete = true

  ingress {
    description = "Allow HTTPS from internet"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "Allow HTTPS outbound for updates"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description     = "Forward to app tier"
    from_port       = 8080
    to_port         = 8080
    protocol        = "tcp"
    cidr_blocks     = [var.app_subnet_cidr]
  }

  tags = merge(local.common_tags, { Name = "${local.name}-public-sg" })
}

resource "aws_security_group" "app" {
  name                   = "${local.name}-app-sg"
  description            = "Private app tier"
  vpc_id                 = aws_vpc.this.id
  revoke_rules_on_delete = true

  ingress {
    description     = "8080 from public tier"
    from_port       = 8080
    to_port         = 8080
    protocol        = "tcp"
    cidr_blocks     = [var.public_subnet_cidr]
  }

  egress {
    description     = "DB traffic"
    from_port       = local.db_port
    to_port         = local.db_port
    protocol        = "tcp"
    cidr_blocks     = [var.db_subnet_a_cidr, var.db_subnet_b_cidr]
  }

  egress {
    description     = "SSM via endpoint"
    from_port       = 443
    to_port         = 443
    protocol        = "tcp"
    cidr_blocks     = [var.app_subnet_cidr]
  }

  tags = merge(local.common_tags, { Name = "${local.name}-app-sg" })
}

resource "aws_security_group" "db" {
  name                   = "${local.name}-db-sg"
  description            = "Database ingress from app only"
  vpc_id                 = aws_vpc.this.id
  revoke_rules_on_delete = true

  ingress {
    description     = "DB from app tier"
    from_port       = local.db_port
    to_port         = local.db_port
    protocol        = "tcp"
    cidr_blocks     = [var.app_subnet_cidr]
  }

  egress {
    description = "No outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["127.0.0.1/32"]
  }

  tags = merge(local.common_tags, { Name = "${local.name}-db-sg" })
}

resource "aws_iam_role" "ec2" {
  name = "${local.name}-ec2-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })

  tags = local.common_tags
}

resource "aws_iam_role_policy_attachment" "ssm_core" {
  role       = aws_iam_role.ec2.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy" "least_privilege" {
  name = "${local.name}-least-privilege"
  role = aws_iam_role.ec2.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ReadOwnParameters"
        Effect = "Allow"
        Action = [
          "ssm:GetParameter",
          "ssm:GetParameters"
        ]
        Resource = "arn:aws:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:parameter/${var.project_name}/${var.environment}/*"
      },
      {
        Sid    = "DecryptOwnSecrets"
        Effect = "Allow"
        Action = [
          "kms:Decrypt",
          "kms:DescribeKey"
        ]
        Resource = var.kms_key_arn
      },
      {
        Sid    = "AppDataBucketAccess"
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:ListBucket"
        ]
        Resource = [
          aws_s3_bucket.app_data.arn,
          "${aws_s3_bucket.app_data.arn}/*"
        ]
      }
    ]
  })
}

data "aws_caller_identity" "current" {}

resource "aws_iam_instance_profile" "ec2" {
  name = "${local.name}-instance-profile"
  role = aws_iam_role.ec2.name

  tags = local.common_tags
}

resource "aws_instance" "app" {
  ami                         = data.aws_ami.al2023.id
  instance_type               = var.instance_type
  subnet_id                   = aws_subnet.app.id
  vpc_security_group_ids      = [aws_security_group.app.id]
  associate_public_ip_address = false
  iam_instance_profile        = aws_iam_instance_profile.ec2.name
  monitoring                  = true

  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required"
  }

  root_block_device {
    encrypted   = true
    kms_key_id  = var.kms_key_arn
    volume_type = "gp3"
    volume_size = 8
  }

  user_data = <<-EOF
              #!/bin/bash
              set -euo pipefail
              dnf -y update
              dnf -y install python3
              mkdir -p /opt/app
              cat >/opt/app/server.py <<'PYEOF'
              from http.server import BaseHTTPRequestHandler, HTTPServer

              class Handler(BaseHTTPRequestHandler):
                  def do_GET(self):
                      self.send_response(200)
                      self.send_header("Content-Type", "text/plain")
                      self.end_headers()
                      self.wfile.write(b"cool-delivery app tier OK")

              HTTPServer(("0.0.0.0", 8080), Handler).serve_forever()
              PYEOF

              nohup python3 /opt/app/server.py >/var/log/app.log 2>&1 &
              EOF

  tags = merge(local.common_tags, { Name = "${local.name}-app" })
}

resource "aws_instance" "public" {
  ami                         = data.aws_ami.al2023.id
  instance_type               = var.instance_type
  subnet_id                   = aws_subnet.public.id
  vpc_security_group_ids      = [aws_security_group.public.id]
  associate_public_ip_address = true
  iam_instance_profile        = aws_iam_instance_profile.ec2.name
  monitoring                  = true

  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required"
  }

  root_block_device {
    encrypted   = true
    kms_key_id  = var.kms_key_arn
    volume_type = "gp3"
    volume_size = 8
  }

  user_data = <<-EOF
              #!/bin/bash
              set -euo pipefail
              dnf -y update
              dnf -y install nginx openssl

              mkdir -p /etc/pki/tls/private
              openssl req -x509 -nodes -newkey rsa:2048 -days 365 \
                -keyout /etc/pki/tls/private/localhost.key \
                -out /etc/pki/tls/certs/localhost.crt \
                -subj "/CN=localhost"

              cat >/etc/nginx/conf.d/default.conf <<'NGINXEOF'
              server {
                listen 443 ssl;
                server_name _;

                ssl_protocols TLSv1.2 TLSv1.3;
                ssl_certificate /etc/pki/tls/certs/localhost.crt;
                ssl_certificate_key /etc/pki/tls/private/localhost.key;

                location / {
                  proxy_pass http://${aws_instance.app.private_ip}:8080;
                  proxy_set_header Host $host;
                  proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
                }
              }
              NGINXEOF

              systemctl enable nginx
              systemctl restart nginx
              EOF

  tags = merge(local.common_tags, { Name = "${local.name}-public" })
}

resource "aws_db_subnet_group" "this" {
  name       = "${local.name}-db-subnet-group"
  subnet_ids = [aws_subnet.db_a.id, aws_subnet.db_b.id]

  tags = merge(local.common_tags, { Name = "${local.name}-db-subnet-group" })
}

resource "aws_db_parameter_group" "tls" {
  name   = "${replace(local.name, "-", "")}-db-params"
  family = local.db_family

  dynamic "parameter" {
    for_each = var.db_engine == "postgres" ? [1] : []
    content {
      name  = "rds.force_ssl"
      value = "1"
    }
  }

  dynamic "parameter" {
    for_each = var.db_engine == "mysql" ? [1] : []
    content {
      name  = "require_secure_transport"
      value = "ON"
    }
  }

  tags = merge(local.common_tags, { Name = "${local.name}-db-params" })
}

resource "aws_db_instance" "main" {
  identifier                  = "${local.name}-db"
  engine                      = var.db_engine
  engine_version              = local.db_engine_version
  instance_class              = local.db_instance_class
  allocated_storage           = var.db_allocated_storage
  storage_type                = "gp2"
  db_subnet_group_name        = aws_db_subnet_group.this.name
  vpc_security_group_ids      = [aws_security_group.db.id]
  username                    = "appadmin"
  password                    = random_password.db.result
  db_name                     = local.db_name
  port                        = local.db_port
  parameter_group_name        = aws_db_parameter_group.tls.name
  backup_retention_period     = var.db_backup_retention
  backup_window               = "03:00-04:00"
  maintenance_window          = "sun:04:00-sun:05:00"
  auto_minor_version_upgrade  = true
  deletion_protection         = true
  skip_final_snapshot         = false
  final_snapshot_identifier   = "${local.name}-final-snapshot"
  copy_tags_to_snapshot       = true
  publicly_accessible         = false
  storage_encrypted           = true
  kms_key_id                  = var.kms_key_arn
  performance_insights_enabled = true
  performance_insights_kms_key_id = var.kms_key_arn
  enabled_cloudwatch_logs_exports = var.db_engine == "postgres" ? ["postgresql"] : ["error", "general", "slowquery"]

  tags = merge(local.common_tags, { Name = "${local.name}-rds" })
}

resource "aws_ssm_parameter" "db_password" {
  name   = "/${var.project_name}/${var.environment}/database/password"
  type   = "SecureString"
  value  = random_password.db.result
  key_id = var.kms_key_arn

  tags = local.common_tags
}

resource "aws_ssm_parameter" "db_endpoint" {
  name  = "/${var.project_name}/${var.environment}/database/endpoint"
  type  = "String"
  value = aws_db_instance.main.endpoint

  tags = local.common_tags
}

resource "aws_s3_bucket" "app_data" {
  bucket        = "${local.name}-data-${data.aws_caller_identity.current.account_id}-${var.aws_region}"
  force_destroy = false

  tags = merge(local.common_tags, { Name = "${local.name}-data" })
}

resource "aws_s3_bucket_versioning" "app_data" {
  bucket = aws_s3_bucket.app_data.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_public_access_block" "app_data" {
  bucket = aws_s3_bucket.app_data.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "app_data" {
  bucket = aws_s3_bucket.app_data.id

  rule {
    apply_server_side_encryption_by_default {
      kms_master_key_id = var.kms_key_arn
      sse_algorithm     = "aws:kms"
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_logging" "app_data" {
  bucket = aws_s3_bucket.app_data.id

  target_bucket = var.central_log_bucket_id
  target_prefix = "s3-access/${var.environment}/"
}

resource "aws_s3_bucket_policy" "app_data_tls" {
  bucket = aws_s3_bucket.app_data.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "DenyInsecureTransport"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource = [
          aws_s3_bucket.app_data.arn,
          "${aws_s3_bucket.app_data.arn}/*"
        ]
        Condition = {
          Bool = {
            "aws:SecureTransport" = "false"
          }
        }
      }
    ]
  })
}

resource "aws_cloudwatch_log_group" "flow_logs" {
  name              = "/aws/vpc/${local.name}/flow-logs"
  retention_in_days = 30
  kms_key_id        = var.kms_key_arn

  tags = local.common_tags
}

resource "aws_iam_role" "flow_logs" {
  name = "${local.name}-flow-logs-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "vpc-flow-logs.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })

  tags = local.common_tags
}

resource "aws_iam_role_policy" "flow_logs" {
  name = "${local.name}-flow-logs-policy"
  role = aws_iam_role.flow_logs.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:DescribeLogGroups",
          "logs:DescribeLogStreams",
          "logs:PutLogEvents"
        ]
        Resource = "${aws_cloudwatch_log_group.flow_logs.arn}:*"
      }
    ]
  })
}

resource "aws_flow_log" "vpc" {
  iam_role_arn             = aws_iam_role.flow_logs.arn
  log_destination          = aws_cloudwatch_log_group.flow_logs.arn
  log_destination_type     = "cloud-watch-logs"
  traffic_type             = "ALL"
  vpc_id                   = aws_vpc.this.id
  max_aggregation_interval = 60

  tags = local.common_tags
}

resource "aws_cloudwatch_metric_alarm" "high_cpu_app" {
  alarm_name          = "${local.name}-app-cpu-high"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 2
  metric_name         = "CPUUtilization"
  namespace           = "AWS/EC2"
  period              = 300
  statistic           = "Average"
  threshold           = 85
  alarm_description   = "High app CPU utilization"
  alarm_actions       = [var.security_alerts_topic]
  treat_missing_data  = "notBreaching"

  dimensions = {
    InstanceId = aws_instance.app.id
  }

  tags = local.common_tags
}
