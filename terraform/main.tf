terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
  required_version = ">= 1.2.0"
}

provider "aws" {
  region = var.region
}

terraform {
  backend "s3" {
    bucket = "app-terraform-state7220"
    key    = "prod/terraform.tfstate"
    region = "us-east-1"
  }
}


# ─── VPC ────────────────────────────────────────────────────────────────────

resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = { Name = "${var.project}-vpc" }
}

resource "aws_subnet" "public" {
  count             = 2
  vpc_id            = aws_vpc.main.id
  cidr_block        = cidrsubnet("10.0.0.0/16", 8, count.index)
  availability_zone = data.aws_availability_zones.available.names[count.index]

  tags = { Name = "${var.project}-public-${count.index}" }
}

resource "aws_subnet" "private" {
  count             = 2
  vpc_id            = aws_vpc.main.id
  cidr_block        = cidrsubnet("10.0.0.0/16", 8, count.index + 10)
  availability_zone = data.aws_availability_zones.available.names[count.index]

  tags = { Name = "${var.project}-private-${count.index}" }
}

data "aws_availability_zones" "available" {}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "${var.project}-igw" }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = { Name = "${var.project}-public-rt" }
}

resource "aws_route_table_association" "public" {
  count          = 2
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# ─── SECURITY GROUPS ────────────────────────────────────────────────────────

resource "aws_security_group" "alb" {
  name        = "${var.project}-alb-sg"
  description = "ALB security group"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.project}-alb-sg" }
}

resource "aws_security_group" "app_instances_sg" {
  name        = "${var.project}-app-instances-sg"
  description = "Security group for Auto-Scaling EC2 Instances"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port       = var.container_port
    to_port         = var.container_port
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  ingress {
    from_port   = 8080
    to_port     = 8080
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Allow SSH access"
  }

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.project}-instances-sg" }
}

resource "aws_security_group" "rds" {
  name        = "${var.project}-rds-sg"
  description = "RDS security group"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port       = 3306
    to_port         = 3306
    protocol        = "tcp"
    security_groups = [aws_security_group.app_instances_sg.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.project}-rds-sg" }
}

# ─── ALB ────────────────────────────────────────────────────────────────────

resource "aws_lb" "main" {
  name               = "${var.project}-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = aws_subnet.public[*].id

  enable_deletion_protection = false

  tags = { Name = "${var.project}-alb" }
}

resource "aws_lb_target_group" "app" {
  name        = "${var.project}-tg"
  port        = var.container_port
  protocol    = "HTTP"
  vpc_id      = aws_vpc.main.id
  target_type = "instance"

  health_check {
    path                = "/"
    healthy_threshold   = 2
    unhealthy_threshold = 3
    interval            = 30
  }

  tags = { Name = "${var.project}-tg" }
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.main.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app.arn
  }
}

# ─── SECRETS & CRYPTOGRAPHY ─────────────────────────────────────────────────

resource "random_password" "db_password" {
  length           = 16
  special          = true
  override_special = "!#$%&*()-_=+[]{}<>:?"
}

resource "aws_kms_key" "secrets" {
  description             = "KMS key for Secrets Manager"
  enable_key_rotation     = true
  deletion_window_in_days = 7
}

resource "aws_secretsmanager_secret" "db_credentials" {
  name       = "${var.project}-db-password"
  kms_key_id = aws_kms_key.secrets.id
}

resource "aws_secretsmanager_secret_version" "db_credentials" {
  secret_id     = aws_secretsmanager_secret.db_credentials.id
  secret_string = random_password.db_password.result
}


# Create the IAM Role for the EC2 instances
resource "aws_iam_role" "ec2_ecr_role" {
  name = "${var.project}-ec2-ecr-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action    = "sts:AssumeRole"
        Effect    = "Allow"
        Principal = { Service = "ec2.amazonaws.com" }
      }
    ]
  })
}

# Attach the standard AWS managed policy for ECR read access
resource "aws_iam_role_policy_attachment" "ecr_read" {
  role       = aws_iam_role.ec2_ecr_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

# Create the Instance Profile that EC2 actually consumes
resource "aws_iam_instance_profile" "ec2_profile" {
  name = "${var.project}-ec2-instance-profile"
  role = aws_iam_role.ec2_ecr_role.name
}

# ─── EC2 AUTO SCALING PERIMETER ─────────────────────────────────────────────

resource "aws_launch_template" "app_lt" {
  name_prefix   = "app-devsecops-lt-"
  image_id      = "ami-0fc5d935ebf8bc3bc" 
  instance_type = "c6i.xlarge"
  key_name      = "devsecops-key"

  iam_instance_profile { name = aws_iam_instance_profile.ec2_profile.name }

  user_data = base64encode(<<-EOF
    #!/bin/bash
    #!/bin/bash
    set -euxo pipefail
    exec > >(tee /var/log/user-data.log) 2>&1
    
    # ─── SYSTEM CONFIGURATION ───────────────────────────────────────────────────
    # Expand memory map limits specifically required by Wazuh Indexer (Elasticsearch backend)
    sysctl -w vm.max_map_count=262144
    echo "vm.max_map_count=262144" >> /etc/sysctl.conf
    
    # ─── DEPENDENCY INSTALLATION ────────────────────────────────────────────────
    apt-get update -y
    apt-get install -y apt-transport-https ca-certificates curl software-properties-common awscli git
    
    # Add official Docker repository keys and configuration
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | apt-key add -
    add-apt-repository "deb [arch=amd64] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable"
    apt-get update -y
    
    # Explicitly install Docker engine along with the required Compose V2 plugin
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
    
    # ─── APPLICATION DEPLOYMENT ─────────────────────────────────────────────────
    # Authenticate against your ECR private registry using your instance profile permissions
    aws ecr get-login-password --region ${var.region} | docker login --username AWS --password-stdin ${split("/", var.image_uri)[0]}
    
    # Pull and run your app container mapped perfectly to host port 5000 for your target group
    docker pull ${var.image_uri}
    docker run -d -p 5000:5000 --name app ${var.image_uri}
    
    # ─── WAZUH MONITORING STACK DEPLOYMENT ──────────────────────────────────────
    # Clone and stage the centralized Docker repository for the monitoring stack
    git clone https://github.com/wazuh/wazuh-docker.git /opt/wazuh-docker
    cd /opt/wazuh-docker
    git checkout v4.14.5
    cd single-node
    
    # Provision the automated internal cluster certificates and spin up the single-node ecosystem
    docker compose -f generate-indexer-certs.yml run --rm generator
    docker compose up -d
    
    # ─── LOCAL HOST AGENT PROVISIONING ──────────────────────────────────────────
    # Import the security signatures and append Wazuh's repository to the local package listings
    curl -s https://packages.wazuh.com/key/GPG-KEY-WAZUH | gpg --dearmor -o /usr/share/keyrings/wazuh.gpg
    echo "deb [signed-by=/usr/share/keyrings/wazuh.gpg] https://packages.wazuh.com/4.x/apt/ stable main" | tee /etc/apt/sources.list.d/wazuh.list
    apt-get update -y
    
    # Bind the local host monitoring agent to target the running manager loopback profile
    WAZUH_MANAGER="127.0.0.1" apt-get install wazuh-agent -y
    
    # Register and start the background OS monitoring engine
    systemctl daemon-reload
    systemctl enable wazuh-agent
    systemctl start wazuh-agent
  EOF
  )

  network_interfaces {
    associate_public_ip_address = true
    security_groups             = [aws_security_group.app_instances_sg.id]
  }

  block_device_mappings {
    device_name = "/dev/sda1"
    ebs {
      volume_size           = 300
      volume_type           = "gp3"
      delete_on_termination = true
    }
  }

  lifecycle {
    create_before_destroy = true 
  }
}

resource "aws_autoscaling_group" "app_asg" {
  name_prefix         = "app-devsecops-asg-"
  desired_capacity    = 1
  max_size            = 2
  min_size            = 1
  vpc_zone_identifier = aws_subnet.public[*].id

  launch_template {
    id      = aws_launch_template.app_lt.id
    version = "$Latest"
  }

  target_group_arns         = [aws_lb_target_group.app.arn]
  health_check_type         = "EC2" 
  health_check_grace_period = 300
}

# ─── RDS ────────────────────────────────────────────────────────────────────

resource "aws_db_subnet_group" "main" {
  name       = "${var.project}-db-subnet-group"
  subnet_ids = aws_subnet.private[*].id

  tags = { Name = "${var.project}-db-subnet-group" }
}

resource "aws_db_instance" "mysql" {
  identifier        = "${var.project}-mysql"
  engine            = "mysql"
  engine_version    = "8.0"
  instance_class    = "db.t3.micro"
  allocated_storage = 20
  storage_type      = "gp2"

  db_name  = "appdb"
  password = random_password.db_password.result
  username = var.db_username
  port     = 3306

  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.rds.id]

  multi_az = true 

  skip_final_snapshot      = true
  delete_automated_backups = true
  deletion_protection      = false

  tags = { Name = "${var.project}-mysql" }
}
