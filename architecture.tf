// ------------  CONFIG AND VARIABLES------------

terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
  required_version = ">= 1.3"
}

variable "region" {
  default = "eu-central-1"
}

variable "availability_zone_a" {
  default = "eu-central-1a"
}

variable "availability_zone_b" {
  default = "eu-central-1b"
}

provider "aws" {
  region = var.region
}

variable "account_id" {
  default = "739275479418"
}

// secret for auth of api gateway to alb
variable "alb_secret" {
  default = "example-password"
}

variable "vpc_cidr" {
  default = "10.1.0.0/16"
}

variable "container_port" {
  default = 3000
}

variable "db_port" {
  default = 5432
}

variable "name_prefix" {
  description = "Prefix for all AWS resource names"
  type        = string
  default     = "iu-finguard"
}

variable "container_name" {
  default = "transaction-processing"
}

output "image_name" {
  value       = "${var.name_prefix}-${var.container_name}"
  description = "Name of the backend container image"
}

output "region" {
  value       = var.region
  description = "Region used"
}

// ------------------- VPC ----------------------

// vpc
resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "${var.name_prefix}-vpc"
  }
}

// public subnet AZ a
resource "aws_subnet" "public_subnet_a" {
  vpc_id                  = aws_vpc.main.id
  availability_zone       = var.availability_zone_a
  map_public_ip_on_launch = true
  cidr_block              = cidrsubnet(var.vpc_cidr, 4, 0)

  tags = {
    Name = "${var.name_prefix}-public-subnet_a"
  }
}

// public subnet AZ b
resource "aws_subnet" "public_subnet_b" {
  vpc_id                  = aws_vpc.main.id
  availability_zone       = var.availability_zone_b
  map_public_ip_on_launch = true
  cidr_block              = cidrsubnet(var.vpc_cidr, 4, 1)

  tags = {
    Name = "${var.name_prefix}-public-subnet_b"
  }
}

// private subnet AZ a
resource "aws_subnet" "private_subnet_a" {
  vpc_id            = aws_vpc.main.id
  availability_zone = var.availability_zone_a
  cidr_block        = cidrsubnet(var.vpc_cidr, 4, 2)

  tags = {
    Name = "${var.name_prefix}-private-subnet_a"
  }
}

// private subnet AZ b
resource "aws_subnet" "private_subnet_b" {
  vpc_id            = aws_vpc.main.id
  availability_zone = var.availability_zone_b
  cidr_block        = cidrsubnet(var.vpc_cidr, 4, 3)

  tags = {
    Name = "${var.name_prefix}-private-subnet_b"
  }
}

// internet gateway attached to vpc 
resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "${var.name_prefix}-igw"
  }
}

// route table for public subnet
resource "aws_route_table" "public_rt" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }

  tags = {
    Name = "${var.name_prefix}-public-rt"
  }
}

// route table asociation with public subnet
resource "aws_route_table_association" "public_assoc_a" {
  subnet_id      = aws_subnet.public_subnet_a.id
  route_table_id = aws_route_table.public_rt.id
}

resource "aws_route_table_association" "public_assoc_b" {
  subnet_id      = aws_subnet.public_subnet_b.id
  route_table_id = aws_route_table.public_rt.id
}

// route table for private subnets
resource "aws_route_table" "private_rt" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "${var.name_prefix}-private-rt"
  }
}

// associate private route table with private subnets
resource "aws_route_table_association" "private_assoc_a" {
  subnet_id      = aws_subnet.private_subnet_a.id
  route_table_id = aws_route_table.private_rt.id
}

resource "aws_route_table_association" "private_assoc_b" {
  subnet_id      = aws_subnet.private_subnet_b.id
  route_table_id = aws_route_table.private_rt.id
}

# List of service interfaces needed for the private subnet
locals {
  aws_services = [    
    "ecs",           # register with the cluster and receive task placements
    "ecs-agent",     # agent communication
    "ecs-telemetry", # send metrics/telemetry
    "ecr.api",       # ECR API
    "ecr.dkr",       # ECR DKR
    "ssm",           # Parameter Store
    "kms",           # KMS
    "logs",          # CloudWatch Logs
    "config",        # AWS Config
    "sts" ,          # STS for IAM roles
    "ssmmessages",   # required for Session Manager
    "ec2messages"    # required for SSM agent communication
  ]
}

// create VPC endpoint for every AWS service used by service inside and attach the VPC endpoints SG
resource "aws_vpc_endpoint" "interface_endpoints" {
  for_each            = toset(local.aws_services)
  vpc_id              = aws_vpc.main.id
  service_name        = "com.amazonaws.${var.region}.${each.value}"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = [aws_subnet.private_subnet_a.id]
  security_group_ids  = [aws_security_group.vpce_sg.id]
  private_dns_enabled = true

  tags = {
    Name = "${var.name_prefix}-${each.value}-endpoint"
  }
}

resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.main.id
  service_name      = "com.amazonaws.eu-central-1.s3"
  vpc_endpoint_type = "Gateway"

  route_table_ids = [aws_route_table.private_rt.id]

  tags = {
    Name = "${var.name_prefix}-s3-endpoint"
  }
}

// ------------------- SECURITY GROUPS ---------------------------

// ALB security group - in poc allows internet access and checks for secret header from api gateway
resource "aws_security_group" "alb_sg" {
  name        = "${var.name_prefix}-alb-sg"
  description = "ALB security group"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"] # public
  }

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # outbound ECS rule defined later
  tags = {
    Name = "${var.name_prefix}-alb-sg"
  }
}

// ECS SG
resource "aws_security_group" "ecs_sg" {
  name        = "${var.name_prefix}-ecs-sg"
  description = "ECS tasks SG"
  vpc_id      = aws_vpc.main.id

  # inbound from ALB
  ingress {
    description     = "App traffic from ALB"
    from_port       = var.container_port
    to_port         = var.container_port
    protocol        = "tcp"
    security_groups = [aws_security_group.alb_sg.id]
  }

  # outbound RDS rule attached later
  # outbound interface endpoints rule attached later
  tags = {
    Name = "${var.name_prefix}-ecs-sg"
  }

}

# EC2 SG
resource "aws_security_group" "ec2_sg" {
  name        = "${var.name_prefix}-ec2-sg"
  description = "EC2 instances SG"
  vpc_id      = aws_vpc.main.id

  # no inbound
  # outbound to interface endpoints later
  tags = {
    Name = "${var.name_prefix}-ec2-sg"
  }
}

# RDS SG
resource "aws_security_group" "rds_sg" {
  name        = "${var.name_prefix}-rds-sg"
  description = "RDS SG"
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "Postgres from ECS"
    from_port       = var.db_port
    to_port         = var.db_port
    protocol        = "tcp"
    security_groups = [aws_security_group.ecs_sg.id]
  }

  # no egress rules -> Terraform will allow all unless override
  tags = {
    Name = "${var.name_prefix}-rds-sg"
  }
}

// ENDPOINT INTERFACES SG
resource "aws_security_group" "vpce_sg" {
  name        = "${var.name_prefix}-vpc-endpoints-sg"
  description = "Interface endpoints SG"
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "HTTPS from ECS"
    from_port       = 443
    to_port         = 443
    protocol        = "tcp"
    security_groups = [aws_security_group.ecs_sg.id]
  }

  ingress {
    description     = "HTTPS from EC2"
    from_port       = 443
    to_port         = 443
    protocol        = "tcp"
    security_groups = [aws_security_group.ec2_sg.id]
  }

  egress {
    description = "Allow all outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.name_prefix}-vpc-endpoints-sg"
  }
}

// EGRESS RULES AND THEIR ATTACHMENT TO EXISTING SGs
# ALB -> ECS
resource "aws_security_group_rule" "alb_to_ecs" {
  type                     = "egress"
  security_group_id        = aws_security_group.alb_sg.id
  from_port                = var.container_port
  to_port                  = var.container_port
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.ecs_sg.id
}

# ECS -> RDS
resource "aws_security_group_rule" "ecs_to_rds" {
  type                     = "egress"
  security_group_id        = aws_security_group.ecs_sg.id
  from_port                = var.db_port
  to_port                  = var.db_port
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.rds_sg.id
}

# ECS -> VPC endpoints (HTTPS)
resource "aws_security_group_rule" "ecs_to_vpce" {
  type                     = "egress"
  security_group_id        = aws_security_group.ecs_sg.id
  from_port                = 443
  to_port                  = 443
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.vpce_sg.id
}

# EC2 -> VPC endpoints (HTTPS)
resource "aws_security_group_rule" "ec2_to_vpce" {
  type                     = "egress"
  security_group_id        = aws_security_group.ec2_sg.id
  from_port                = 443
  to_port                  = 443
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.vpce_sg.id
}

# EC2 -> S3 gateway endpoint (image layers)
resource "aws_security_group_rule" "ec2_to_s3" {
  type              = "egress"
  security_group_id = aws_security_group.ec2_sg.id
  from_port         = 443
  to_port           = 443
  protocol          = "tcp"
  prefix_list_ids   = [data.aws_prefix_list.s3.id]  # S3 managed prefix list
}

# ECS_S3
resource "aws_security_group_rule" "ecs_to_s3" {
  type              = "egress"
  security_group_id = aws_security_group.ecs_sg.id
  from_port         = 443
  to_port           = 443
  protocol          = "tcp"
  prefix_list_ids   = [data.aws_prefix_list.s3.id]
}

# Data source for S3 prefix list
data "aws_prefix_list" "s3" {
  name = "com.amazonaws.eu-central-1.s3"
}

# ALB -> EC2 instance (dynamic ports for bridge mode)
resource "aws_security_group_rule" "alb_to_ec2" {
  type                     = "egress"
  security_group_id        = aws_security_group.alb_sg.id
  from_port                = 32768
  to_port                  = 65535
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.ec2_sg.id
}

# EC2 <- ALB
resource "aws_security_group_rule" "ec2_from_alb" {
  type                     = "ingress"
  security_group_id        = aws_security_group.ec2_sg.id
  from_port                = 32768
  to_port                  = 65535
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.alb_sg.id
}

# EC2 -> RDS
resource "aws_security_group_rule" "ec2_to_rds" {
  type                     = "egress"
  security_group_id        = aws_security_group.ec2_sg.id
  from_port                = var.db_port
  to_port                  = var.db_port
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.rds_sg.id
}

# RDS <- EC2
resource "aws_security_group_rule" "rds_from_ec2" {
  type                     = "ingress"
  security_group_id        = aws_security_group.rds_sg.id
  from_port                = var.db_port
  to_port                  = var.db_port
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.ec2_sg.id
}

// ---------------------- IAM ROLES ---------------------

// esc task role - main role the application uses
resource "aws_iam_role" "ecs_task_role" {
  name = "${var.name_prefix}-ecs-task-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect = "Allow",
        Principal = {
          Service = "ecs-tasks.amazonaws.com"
        },
        Action = "sts:AssumeRole"
      }
    ]
  })
}
// attach policies for ecs task role
resource "aws_iam_role_policy" "ecs_task_policy" {
  name = "${var.name_prefix}-ecs-task-policy"
  role = aws_iam_role.ecs_task_role.id

  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect = "Allow",
        Action = [
          "ssm:GetParameter",
          "ssm:GetParameters",
          "ssm:GetParameterHistory"
        ],
        Resource = "*"
      },
      {
        Effect   = "Allow",
        Action   = ["kms:Decrypt"],
        Resource = "*",
        Condition = {
          "StringEquals" : {
            "kms:ViaService" : "ssm.${var.region}.amazonaws.com"
          }
        }
      },
      {
        Effect = "Allow",
        Action = [
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ],
        Resource = "*"
      }
    ]
  })
}

// ecs execution role 
resource "aws_iam_role" "ecs_execution_role" {
  name = "${var.name_prefix}-ecs-execution-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect = "Allow",
        Principal = {
          Service = "ecs-tasks.amazonaws.com"
        },
        Action = "sts:AssumeRole"
      }
    ]
  })
}
// attach policy for ecs execution role
resource "aws_iam_role_policy_attachment" "ecs_execution_policy" {
  role       = aws_iam_role.ecs_execution_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}



// role for EC2 instances running ECS
resource "aws_iam_role" "ecs_instance_role" {
  name = "${var.name_prefix}-ecs-instance-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17",
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
}

resource "aws_iam_role_policy" "ecs_execution_ssm" {
  name = "${var.name_prefix}-ecs-execution-ssm"
  role = aws_iam_role.ecs_execution_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["ssm:GetParameters", "ssm:GetParameter"]
        Resource = [
          "arn:aws:ssm:${var.region}:${var.account_id}:parameter/${var.name_prefix}/*",
          "arn:aws:ssm:${var.region}:${var.account_id}:parameter//${var.name_prefix}/*"
        ]
      },
      {
        Effect   = "Allow"
        Action   = ["kms:Decrypt"]
        Resource = "*"
      }
    ]
  })
}

// atach AWS Managed Policy to ECS EC2 role
resource "aws_iam_role_policy_attachment" "ecs_instance_policy" {
  role       = aws_iam_role.ecs_instance_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEC2ContainerServiceforEC2Role"
}

resource "aws_iam_role_policy_attachment" "ecs_instance_ssm" {
  role       = aws_iam_role.ecs_instance_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

// -------------------------- S3 -------------------------------

resource "aws_s3_bucket" "frontend" {
  bucket        = "${var.name_prefix}-frontend"
  force_destroy = true

  tags = {
    Name = "${var.name_prefix}-frontend"
  }
}

resource "aws_s3_bucket_public_access_block" "frontend" {
  bucket = aws_s3_bucket.frontend.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "frontend" {
  bucket = aws_s3_bucket.frontend.id

  rule {
    apply_server_side_encryption_by_default {
        sse_algorithm = "AES256"  # ← was aws:kms
    }
  }
}

data "aws_iam_policy_document" "frontend_bucket_policy" {
  # 1) Allow CloudFront (this specific distribution) to read objects
  statement {
    sid    = "AllowCloudFrontAccessViaOAC"
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["cloudfront.amazonaws.com"]
    }

    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.frontend.arn}/*"]

    condition {
      test     = "StringEquals"
      variable = "AWS:SourceArn"
      values   = [aws_cloudfront_distribution.main.arn]
    }
  }

  # 2) Deny unencrypted uploads
  statement {
    sid     = "DenyUnEncryptedObjectUploads"
    effect  = "Deny"
    actions = ["s3:PutObject"]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    resources = ["${aws_s3_bucket.frontend.arn}/*"]

    condition {
  test     = "StringNotEquals"
  variable = "s3:x-amz-server-side-encryption"
  values   = ["AES256"]
    }
  }
}

// bucket policy attached to s3
resource "aws_s3_bucket_policy" "frontend" {
  bucket = aws_s3_bucket.frontend.id
  policy = data.aws_iam_policy_document.frontend_bucket_policy.json
}

output "frontend_bucket_name" {
  value       = aws_s3_bucket.frontend.bucket
  description = "Name of the S3 bucket for frontend"
}

output "frontend_bucket_url" {
  value       = "s3://${aws_s3_bucket.frontend.bucket}"
  description = "S3 URL of the frontend bucket"
}

// ------------------ CLOUDFRONT ---------------

// cloudfront OAC
resource "aws_cloudfront_origin_access_control" "frontend" {
  name                              = "${var.name_prefix}-oac"
  description                       = "OAC for S3 frontend"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

// cloudfront distribution with 2 paths
resource "aws_cloudfront_distribution" "main" {
  enabled = true
  default_root_object = "index.html"

  # --- S3 origin ---
  origin {
    domain_name = aws_s3_bucket.frontend.bucket_regional_domain_name
    origin_id   = "s3-frontend"

    origin_access_control_id = aws_cloudfront_origin_access_control.frontend.id
  }

  # Default behavior → S3
  default_cache_behavior {
    target_origin_id       = "s3-frontend"
    viewer_protocol_policy = "redirect-to-https"

    allowed_methods = ["GET", "HEAD"]
    cached_methods  = ["GET", "HEAD"]
    compress        = true

   forwarded_values {
      query_string = true
      headers      = []

      cookies {
        forward = "none"
      }
    }
  }

  # API origin → API Gateway
  origin {
    domain_name = replace(aws_apigatewayv2_api.backend.api_endpoint, "https://", "")
    origin_id   = "api-origin"

    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "https-only"
      origin_ssl_protocols   = ["TLSv1.2"]
    }
  }

  # /api/* → API Gateway
  ordered_cache_behavior {
    path_pattern           = "/api/*"
    target_origin_id       = "api-origin"
    viewer_protocol_policy = "redirect-to-https"

    allowed_methods = ["GET", "HEAD", "OPTIONS", "POST", "PUT", "DELETE", "PATCH"]
    cached_methods  = ["GET", "HEAD"]

    forwarded_values {
        query_string = true
        headers      = ["Accept", "Authorization", "Content-Type", "Origin"]  # ← don't forward Host

        cookies {
        forward = "all"
        }
    }
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    cloudfront_default_certificate = true
  }
}

locals {
  frontend_url = "https://${aws_cloudfront_distribution.main.domain_name}"
}

output "cloudfront_domain" {
  value       = aws_cloudfront_distribution.main.domain_name
  description = "CloudFront URL for frontend"
}

// ---------------------- ALB ---------------------

// in PoC, ALB is PUBLIC and receives header from API gateway 
resource "aws_lb" "main" {
  name               = "${var.name_prefix}-alb"
  load_balancer_type = "application"

  subnets         = [aws_subnet.public_subnet_a.id, aws_subnet.public_subnet_b.id]
  security_groups = [aws_security_group.alb_sg.id]

  internal = false # IMPORTANT
}

// Target group
resource "aws_lb_target_group" "main" {
  name        = "${var.name_prefix}-tg-v3"
  port        = var.container_port
  protocol    = "HTTP"
  vpc_id      = aws_vpc.main.id
  target_type = "instance"

  health_check {
    path = "/health"
  }

  tags = {
    Name = "${var.name_prefix}-tg-v3"
  }

  # Ensure listeners/rules are destroyed before this TG
  lifecycle {
    create_before_destroy = true
  }
}

// ALB Listener (HTTP only) with default 403
resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.main.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = "fixed-response"

    fixed_response {
      status_code  = "403"
      content_type = "text/plain"
      message_body = "Forbidden"
    }
  }
}

# Listener rule that forwards only if header matches
resource "aws_lb_listener_rule" "internal_token" {
  listener_arn = aws_lb_listener.http.arn
  priority     = 10

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.main.arn
  }

  condition {
    http_header {
      http_header_name = "X-Internal-Token"
      values           = [var.alb_secret]
    }
  }
}

// ----------------- API GATEWAY -------------------

// api gateway
resource "aws_apigatewayv2_api" "backend" {
  name          = "${var.name_prefix}-api"
  protocol_type = "HTTP"
}

// api gateway Integration - in PoC, api gateway resolves https and adds a secret header
resource "aws_apigatewayv2_integration" "alb" {
  api_id             = aws_apigatewayv2_api.backend.id
  integration_type   = "HTTP_PROXY"
  integration_method = "ANY"
  integration_uri    = "http://${aws_lb.main.dns_name}/{proxy}"  # ← add /{proxy}

  request_parameters = {
    "overwrite:header.X-Internal-Token" = var.alb_secret
  }
}

// api gateway Route
resource "aws_apigatewayv2_route" "default" {
  api_id    = aws_apigatewayv2_api.backend.id
  route_key = "ANY /{proxy+}"

  target = "integrations/${aws_apigatewayv2_integration.alb.id}"
}

// api gateway Stage
resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.backend.id
  name        = "$default"
  auto_deploy = true
}

// ---------------------- ECS ------------------------  

// ecs cluster 
resource "aws_ecs_cluster" "main" {
  name = "${var.name_prefix}-ecs-cluster"

  setting {
    name  = "containerInsights"
    value = "enabled"
  }
}

output "ecs_cluster_name" {
  value       = aws_ecs_cluster.main.name
  description = "ECS Cluster name"
}

// ecs task definition
resource "aws_ecs_task_definition" "app" {
  family                   = "${var.name_prefix}-task"
  requires_compatibilities = ["EC2"]
  network_mode             = "bridge"
  cpu                      = 256
  memory                   = 400

  // iam roles
  task_role_arn      = aws_iam_role.ecs_task_role.arn
  execution_role_arn = aws_iam_role.ecs_execution_role.arn

  // image for transaction processing
  container_definitions = jsonencode([{
    name      = "${var.name_prefix}-${var.container_name}"
    image     = "${aws_ecr_repository.ecr.repository_url}:latest"
    essential = true

        # ADD THIS BLOCK
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = "/ecs/${var.name_prefix}-task"
        "awslogs-region"        = var.region
        "awslogs-stream-prefix" = "ecs"
      }
    }

    portMappings = [
      {
        containerPort = var.container_port
        hostPort      = 0
        protocol      = "tcp"
      }
    ]

    environment = [
      {
        name  = "PORT"
        value = tostring(var.container_port)
      },
      {
        name  = "FRONTEND_URL"
        value = local.frontend_url
      }
    ]

    secrets = [
      {
        name      = "DB_PASSWORD"
        valueFrom = aws_ssm_parameter.db_password.arn
      },
      {
        name      = "DB_USER"
        valueFrom = aws_ssm_parameter.db_user.arn
      },
      {
        name      = "DB_HOST"
        valueFrom = aws_ssm_parameter.db_host.arn
      },
      {
        name      = "DB_NAME"
        valueFrom = aws_ssm_parameter.db_name.arn
      },
      {
        name      = "DB_PORT"
        valueFrom = aws_ssm_parameter.db_port.arn
      }
    ]
  }])
}

// launch template for ec2 instacnes
resource "aws_launch_template" "ecs" {
  name_prefix   = "${var.name_prefix}-ecs-launchtemp"
  image_id      = data.aws_ami.ecs_optimized.id
  instance_type = "t2.micro"

  iam_instance_profile {
    name = aws_iam_instance_profile.ecs_instance_profile.name
  }

  network_interfaces {
    subnet_id                   = aws_subnet.private_subnet_a.id
    security_groups             = [aws_security_group.ec2_sg.id] // not ecs sg ? 
    associate_public_ip_address = false
  }

  user_data = base64encode(<<-EOF
    #!/bin/bash
    echo "ECS_CLUSTER=${aws_ecs_cluster.main.name}" >> /etc/ecs/ecs.config
  EOF
  )

  tag_specifications {
    resource_type = "instance"

    tags = {
      Name = "${var.name_prefix}-ecs-instance"
    }
  }
}

// data source for ecs optimized ami
data "aws_ami" "ecs_optimized" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["amzn2-ami-ecs-hvm-*-x86_64-ebs"] // keep hardcoded ? 
  }
}

// ECS Service wired to ALB tg that runs tasks from app task definition and attaches them to tg
resource "aws_ecs_service" "app" {
  name            = "${var.name_prefix}-ecs-service"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.app.arn
  desired_count   = 1
  launch_type     = "EC2"

  deployment_minimum_healthy_percent = 0  
  deployment_maximum_percent         = 200

  load_balancer {
    target_group_arn = aws_lb_target_group.main.arn
    container_name   = "${var.name_prefix}-${var.container_name}"
    container_port   = var.container_port
  }

  depends_on = [
    aws_lb_listener.http,
    aws_autoscaling_group.ecs
  ]
}

output "ecs_service_name" {
  value       = aws_ecs_service.app.name
  description = "ECS Service name"
}

// ------------------- EC2 ------------------ // ??? 

// autoscaling group 
resource "aws_autoscaling_group" "ecs" {
  name                      = "${var.name_prefix}-ecs-asg"
  desired_capacity          = 1
  max_size                  = 1
  min_size                  = 1
  vpc_zone_identifier       = [aws_subnet.private_subnet_a.id]
  health_check_type         = "EC2"
  health_check_grace_period = 300

  launch_template {
    id      = aws_launch_template.ecs.id
    version = "$Latest"
  }

  tag {
    key                 = "Name"
    value               = "${var.name_prefix}-ecs-instance"
    propagate_at_launch = true
  }

  lifecycle {
    create_before_destroy = true
  }
}

// ec2 instance profile that attaches the iam role
resource "aws_iam_instance_profile" "ecs_instance_profile" {
  name = "${var.name_prefix}-ecs-instance-profile"
  role = aws_iam_role.ecs_instance_role.name
}

// ------------------- RDS ------------------

# Generate a random password for the RDS master user
resource "random_password" "rds_master" {
  length  = 16
  special = true
}

# Dummy private subnet to satisfy 2-subnet requirement
# resource "aws_subnet" "dummy_private" {
#   vpc_id                  = aws_vpc.main.id       # Replace with your VPC ID
#   cidr_block              = "10.0.99.0/24"        # Choose a non-conflicting subnet
#   availability_zone       = var.availability_zone_a # Dummy AZ
#   map_public_ip_on_launch = false
#   tags = {
#     Name = "${var.name_prefix}-dummy-private-subnet"
#   }
# }

# RDS DB subnet group including existing private subnet + dummy
resource "aws_db_subnet_group" "rds_subnet_group" {
  name = "${var.name_prefix}-subnet-group-v2"
  subnet_ids = [
    aws_subnet.private_subnet_a.id, # Replace with your main private subnet
    aws_subnet.private_subnet_b.id
  ]

  tags = {
    Name = "${var.name_prefix}-subnet-group-v2"
  }
}

# RDS PostgreSQL instance
resource "aws_db_instance" "rds_db" {
  identifier                      = "${var.name_prefix}-db"
  engine                          = "postgres"
  engine_version                  = "16"
  instance_class                  = "db.t3.micro"
  allocated_storage               = 20
  storage_type                    = "gp3"
  username                        = "postgres"
  db_name                         = "finguard"
  password                        = random_password.rds_master.result
  port                            = var.db_port
  db_subnet_group_name            = aws_db_subnet_group.rds_subnet_group.name
  vpc_security_group_ids          = [aws_security_group.rds_sg.id]
  multi_az                        = false
  backup_retention_period         = 1
  auto_minor_version_upgrade      = true
  publicly_accessible             = false
  storage_encrypted               = true
  kms_key_id                      = null # get automatic default AWS-managed KMS key
  copy_tags_to_snapshot           = true
  deletion_protection             = false
  enabled_cloudwatch_logs_exports = ["postgresql", "iam-db-auth-error"] # CloudWatch logs export
  ca_cert_identifier              = "rds-ca-rsa2048-g1"                 # RDS CA certificate
  skip_final_snapshot             = true                                # skip for Free Tier support
}

# Output the autogenerated password
output "rds_master_password" {
  value       = random_password.rds_master.result
  description = "Autogenerated RDS master password. Stored securely in ssm parameter store"
  sensitive   = true
}

// ------------------- ECR --------------------------

// ecr repository
resource "aws_ecr_repository" "ecr" {
  name = "${var.name_prefix}-ecr"

  image_tag_mutability = "MUTABLE"
}

output "ecr_repository_url" {
  value = aws_ecr_repository.ecr.repository_url
}

// ------------ SSM PARAMETER STORE ------------------

// secure string - db password
resource "aws_ssm_parameter" "db_password" {
  name  = "/${var.name_prefix}/db/password"
  type  = "SecureString"
  value = random_password.rds_master.result
}
// db user
resource "aws_ssm_parameter" "db_user" {
  name  = "/${var.name_prefix}/db/user"
  type  = "String"
  value = aws_db_instance.rds_db.username
}
// db host
resource "aws_ssm_parameter" "db_host" {
  name  = "/${var.name_prefix}/db/host"
  type  = "String"
  value = aws_db_instance.rds_db.address
}

// db name
resource "aws_ssm_parameter" "db_name" {
  name  = "/${var.name_prefix}/db/name"
  type  = "String"
  value = aws_db_instance.rds_db.db_name
}

// db port 
resource "aws_ssm_parameter" "db_port" {
  name  = "/${var.name_prefix}/db/port"
  type  = "String"
  value = aws_db_instance.rds_db.port
}

// ------------ KMS ----------------
// no customer-managed KMS keys, only AWS-managed

// --------------------- CLOUDWATCH --------------

// log group for ecs tasks
resource "aws_cloudwatch_log_group" "ecs" {
  name              = "/ecs/${var.name_prefix}-task"
  retention_in_days = 7
}
