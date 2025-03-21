provider "aws" {
  region = var.aws_region
}

# управление доступом к кластеру

locals {
  cluster_name = "${var.cluster_name}-${var.env_name}"
}

# EKS Cluster Resources
# IAM Role для управления EKS
resource "aws_iam_role" "ms-cluster" {
  name = local.cluster_name

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "eks.amazonaws.com"
      }
      Action = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ms-cluster-AmazonEKSClusterPolicy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
  role       = aws_iam_role.ms-cluster.name
}

# Security Group
resource "aws_security_group" "ms-cluster" {
  name        = local.cluster_name
  description = "Cluster communication with worker nodes"
  vpc_id      = var.vpc_id
  tags = {
    Name = "ms-up-running"
  }
}

# Разделяем ingress и egress правила (Terraform best practice)
resource "aws_security_group_rule" "ms-cluster-ingress" {
  type              = "ingress"
  security_group_id = aws_security_group.ms-cluster.id
  description       = "Inbound traffic from within the security group"
  from_port         = 0
  to_port           = 0
  protocol         = "-1"
  cidr_blocks       = ["0.0.0.0/0"]
  self              = true
}

resource "aws_security_group_rule" "ms-cluster-egress" {
  type              = "egress"
  security_group_id = aws_security_group.ms-cluster.id
  from_port         = 0
  to_port           = 0
  protocol         = "-1"
  cidr_blocks       = ["0.0.0.0/0"]
}

# EKS Cluster
resource "aws_eks_cluster" "ms-up-running" {
  name     = local.cluster_name
  role_arn = aws_iam_role.ms-cluster.arn

  vpc_config {
    security_group_ids = [aws_security_group.ms-cluster.id]
    subnet_ids         = var.cluster_subnet_ids
  }

  depends_on = [
    aws_iam_role_policy_attachment.ms-cluster-AmazonEKSClusterPolicy
  ]
}

# IAM Role для узлов
resource "aws_iam_role" "ms-node" {
  name = "${local.cluster_name}-node"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "ec2.amazonaws.com"
      }
      Action = "sts:AssumeRole"
    }]
  })
}

# Прикрепляем политики для узлов
resource "aws_iam_role_policy_attachment" "ms-node-AmazonEKSWorkerNodePolicy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
  role       = aws_iam_role.ms-node.name
}

resource "aws_iam_role_policy_attachment" "ms-node-AmazonEKS_CNI_Policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
  role       = aws_iam_role.ms-node.name
}

resource "aws_iam_role_policy_attachment" "ms-node-AmazonEC2ContainerRegistryReadOnly" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
  role       = aws_iam_role.ms-node.name
}

# Группа узлов
resource "aws_eks_node_group" "ms-node-group" {
  cluster_name    = aws_eks_cluster.ms-up-running.name
  node_group_name = "microservices"
  node_role_arn   = aws_iam_role.ms-node.arn
  subnet_ids      = var.nodegroup_subnet_ids

  scaling_config {
    desired_size = var.nodegroup_desired_size
    max_size     = var.nodegroup_max_size
    min_size     = var.nodegroup_min_size
  }

  disk_size      = var.nodegroup_disk_size
  instance_types = tolist(var.nodegroup_instance_types) # Убедимся, что это список

  depends_on = [
    aws_iam_role_policy_attachment.ms-node-AmazonEKSWorkerNodePolicy,
    aws_iam_role_policy_attachment.ms-node-AmazonEKS_CNI_Policy,
    aws_iam_role_policy_attachment.ms-node-AmazonEC2ContainerRegistryReadOnly,
  ]
}

# kubeconfig для доступа к кластеру
resource "local_file" "kubeconfig" {
  content = templatefile("${path.module}/templates/kubeconfig.tmpl", {
    cluster_name    = aws_eks_cluster.ms-up-running.name
    cluster_arn     = aws_eks_cluster.ms-up-running.arn
    cluster_ca_data = aws_eks_cluster.ms-up-running.certificate_authority[0].data
    cluster_endpoint = aws_eks_cluster.ms-up-running.endpoint
  })
  filename = "${path.module}/kubeconfig"
}

/*
#  Use data to ensure that the cluster is up before we start using it
data "aws_eks_cluster" "msur" {
  name = aws_eks_cluster.ms-up-running.id
}

# Use kubernetes provider to work with the kubernetes cluster API
provider "kubernetes" {
  load_config_file       = false
  cluster_ca_certificate = base64decode(data.aws_eks_cluster.msur.certificate_authority.0.data)
  host                   = data.aws_eks_cluster.msur.endpoint
  exec {
    api_version = "client.authentication.k8s.io/v1alpha1"
    command     = "aws-iam-authenticator"
    args        = ["token", "-i", "${data.aws_eks_cluster.msur.name}"]
  }
}

# Create a namespace for microservice pods 
resource "kubernetes_namespace" "ms-namespace" {
  metadata {
    name = var.ms_namespace
  }
}
*/
