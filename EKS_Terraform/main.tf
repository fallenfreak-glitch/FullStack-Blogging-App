# -----------------------------
# Provider Configuration
# -----------------------------
provider "aws" {
  region = "ap-south-1"  # Defines the AWS region where resources will be created (Mumbai region)
}

# -----------------------------
# VPC Configuration
# -----------------------------
resource "aws_vpc" "devopsshack_vpc" {
  cidr_block = "10.0.0.0/16"  # Defines the IP range for the VPC (65536 IPs total)

  tags = {
    Name = "devopsshack-vpc"  # Adds a tag (helps identify the VPC in AWS console)
  }
}

# -----------------------------
# Subnet Configuration
# -----------------------------
resource "aws_subnet" "devopsshack_subnet" {
  count = 2  # Creates two subnets (for HA across two Availability Zones)

  vpc_id                  = aws_vpc.devopsshack_vpc.id  # Associates subnets with the created VPC
  cidr_block              = cidrsubnet(aws_vpc.devopsshack_vpc.cidr_block, 8, count.index)
  # Uses cidrsubnet() to automatically divide the main VPC CIDR into smaller subnets

  availability_zone       = element(["ap-south-1a", "ap-south-1b"], count.index)
  # Assigns subnets to different AZs for redundancy

  map_public_ip_on_launch = true  # Assigns public IPs to EC2 instances launched in this subnet

  tags = {
    Name = "devopsshack-subnet-${count.index}"  # Names subnets as devopsshack-subnet-0, devopsshack-subnet-1
  }
}

# -----------------------------
# Internet Gateway (IGW)
# -----------------------------
resource "aws_internet_gateway" "devopsshack_igw" {
  vpc_id = aws_vpc.devopsshack_vpc.id  # Attaches IGW to the VPC to enable internet access

  tags = {
    Name = "devopsshack-igw"
  }
}

# -----------------------------
# Route Table
# -----------------------------
resource "aws_route_table" "devopsshack_route_table" {
  vpc_id = aws_vpc.devopsshack_vpc.id  # Associates route table with the VPC

  route {
    cidr_block = "0.0.0.0/0"  # Route all internet traffic
    gateway_id = aws_internet_gateway.devopsshack_igw.id  # Through the Internet Gateway
  }

  tags = {
    Name = "devopsshack-route-table"
  }
}

# -----------------------------
# Route Table Association
# -----------------------------
resource "aws_route_table_association" "a" {
  count          = 2  # Associates both subnets with the route table
  subnet_id      = aws_subnet.devopsshack_subnet[count.index].id
  route_table_id = aws_route_table.devopsshack_route_table.id
}

# -----------------------------
# Security Groups
# -----------------------------

# Security Group for EKS Control Plane (Cluster)
resource "aws_security_group" "devopsshack_cluster_sg" {
  vpc_id = aws_vpc.devopsshack_vpc.id  # Belongs to same VPC

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]  # Allow all outbound traffic
  }

  tags = {
    Name = "devopsshack-cluster-sg"
  }
}

# Security Group for EKS Worker Nodes
resource "aws_security_group" "devopsshack_node_sg" {
  vpc_id = aws_vpc.devopsshack_vpc.id

  ingress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]  # Allow all inbound (for demo; should be restricted in production)
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "devopsshack-node-sg"
  }
}

# -----------------------------
# EKS Cluster
# -----------------------------
resource "aws_eks_cluster" "devopsshack" {
  name     = "devopsshack-cluster"  # Cluster name
  role_arn = aws_iam_role.devopsshack_cluster_role.arn  # IAM role with EKS permissions

  vpc_config {
    subnet_ids         = aws_subnet.devopsshack_subnet[*].id  # Attach cluster to the created subnets
    security_group_ids = [aws_security_group.devopsshack_cluster_sg.id]  # Attach cluster security group
  }
}

# -----------------------------
# EKS Node Group (Worker Nodes)
# -----------------------------
resource "aws_eks_node_group" "devopsshack" {
  cluster_name    = aws_eks_cluster.devopsshack.name  # Associate with EKS cluster
  node_group_name = "devopsshack-node-group"          # Node group name
  node_role_arn   = aws_iam_role.devopsshack_node_group_role.arn  # IAM role for nodes
  subnet_ids      = aws_subnet.devopsshack_subnet[*].id  # Nodes will be launched in these subnets

  scaling_config {
    desired_size = 3  # Start with 3 nodes
    max_size     = 3  # Max limit
    min_size     = 3  # Min nodes (static size cluster)
  }

  instance_types = ["t2.large"]  # EC2 instance type used for worker nodes

  remote_access {
    ec2_ssh_key = var.ssh_key_name  # SSH key pair to access worker nodes
    source_security_group_ids = [aws_security_group.devopsshack_node_sg.id]
  }
}

# -----------------------------
# IAM Role for EKS Cluster
# -----------------------------
resource "aws_iam_role" "devopsshack_cluster_role" {
  name = "devopsshack-cluster-role"

  assume_role_policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "eks.amazonaws.com"  # EKS service can assume this role
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF
}

# Attach EKS cluster policy to role
resource "aws_iam_role_policy_attachment" "devopsshack_cluster_role_policy" {
  role       = aws_iam_role.devopsshack_cluster_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}

# -----------------------------
# IAM Role for Worker Nodes
# -----------------------------
resource "aws_iam_role" "devopsshack_node_group_role" {
  name = "devopsshack-node-group-role"

  assume_role_policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "ec2.amazonaws.com"  # EC2 instances (nodes) can assume this role
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF
}

# Attach necessary policies for node group to function
resource "aws_iam_role_policy_attachment" "devopsshack_node_group_role_policy" {
  role       = aws_iam_role.devopsshack_node_group_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
}

resource "aws_iam_role_policy_attachment" "devopsshack_node_group_cni_policy" {
  role       = aws_iam_role.devopsshack_node_group_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
}

resource "aws_iam_role_policy_attachment" "devopsshack_node_group_registry_policy" {
  role       = aws_iam_role.devopsshack_node_group_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}
