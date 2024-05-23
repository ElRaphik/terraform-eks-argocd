resource "aws_iam_role" "eks_cluster" {
  name               = "tf-argo-eks-cluster"
  assume_role_policy = data.aws_iam_policy_document.assume_role_eks.json
}

resource "aws_iam_role_policy_attachment" "aws_eks_cluster_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
  role       = aws_iam_role.eks_cluster.name
}

resource "aws_iam_role_policy_attachment" "aws_eks_vpc_resource_controller" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSVPCResourceController"
  role       = aws_iam_role.eks_cluster.name
}

resource "aws_security_group" "eks" {
  name        = "tf-argo-eks"
  description = "sg for eks cluster"
  vpc_id      = aws_vpc.eks.id

  tags = {
    Name = "tf-argo-eks"
  }
}

resource "aws_vpc_security_group_ingress_rule" "allow_local_network" {
  security_group_id = aws_security_group.eks.id

  cidr_ipv4   = aws_vpc.eks.cidr_block
  from_port   = 0
  ip_protocol = "tcp"
  to_port     = 65535
}

resource "aws_eks_cluster" "test" {
  name     = "tf-argo-cluster"
  role_arn = aws_iam_role.eks_cluster.arn
  version  = "1.27"

  vpc_config {
    endpoint_private_access = false
    endpoint_public_access  = true
    security_group_ids      = [aws_security_group.eks.id, aws_security_group.eks_worker.id]
    subnet_ids              = [aws_subnet.private_1.id, aws_subnet.private_2.id]
  }

  depends_on = [
    aws_iam_role_policy_attachment.aws_eks_cluster_policy,
    aws_iam_role_policy_attachment.aws_eks_vpc_resource_controller,
    aws_subnet.private_1,
    aws_subnet.private_2
  ]
}

resource "aws_iam_role" "eks_worker" {
  name               = "tf-argo-eks-worker"
  assume_role_policy = data.aws_iam_policy_document.assume_role_ec2.json
}

resource "aws_iam_role_policy_attachment" "eks_worker_node_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
  role       = aws_iam_role.eks_worker.name
}

resource "aws_iam_role_policy_attachment" "eks_worker_cni_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
  role       = aws_iam_role.eks_worker.name
}

resource "aws_iam_role_policy_attachment" "eks_worker_ecr_readonly_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
  role       = aws_iam_role.eks_worker.name
}

resource "aws_iam_instance_profile" "eks_worker" {
  name = "tf-argo-eks-worker-ist-pro"
  role = aws_iam_role.eks_worker.name
}

resource "aws_security_group" "eks_worker" {
  name        = "tf-argo-eks-worker"
  description = "sg for eks worker"
  vpc_id      = aws_vpc.eks.id

  tags = {
    Name = "tf-argo-eks-worker"
  }
}

resource "aws_vpc_security_group_ingress_rule" "eks_worker_allow_local" {
  security_group_id = aws_security_group.eks_worker.id

  cidr_ipv4   = aws_vpc.eks.cidr_block
  from_port   = 0
  ip_protocol = "tcp"
  to_port     = 65535
}

resource "aws_vpc_security_group_egress_rule" "eks_worker_egress" {
  security_group_id = aws_security_group.eks_worker.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

resource "aws_launch_template" "eks_worker" {
  name                   = "tf-argo-worker"
  ebs_optimized          = true
  image_id               = "ami-0d6687e6de0bc6bac"
  instance_type          = "t3.small"
  key_name               = "rsoranzo+2024-05@aws"
  update_default_version = true
  vpc_security_group_ids = [aws_security_group.eks_worker.id]

  user_data = base64encode(templatefile(
    "templates/user-data.tpl",
    {
      #bootstrap_extra_args = "",
      cluster_auth_base64 = aws_eks_cluster.test.certificate_authority[0].data,
      cluster_endpoint    = aws_eks_cluster.test.endpoint,
      cluster_name        = "tf-argo-cluster",
    }
  ))

  iam_instance_profile {
    arn = aws_iam_instance_profile.eks_worker.arn
  }

  lifecycle {
    create_before_destroy = true
  }

  depends_on = [aws_eks_cluster.test]
}

resource "aws_autoscaling_group" "eks_worker" {
  name                = "tf-argo-eks-worker"
  vpc_zone_identifier = [aws_subnet.private_1.id, aws_subnet.private_2.id]
  desired_capacity    = 1
  max_size            = 1
  min_size            = 1

  launch_template {
    id      = aws_launch_template.eks_worker.id
    version = "$Latest"
  }

  tag {
    key                 = "Name"
    value               = "tf-argo-eks-worker"
    propagate_at_launch = true
  }

  tag {
    key                 = "kubernetes.io/cluster/tf-argo-cluster"
    value               = "owned"
    propagate_at_launch = true
  }

  tag {
    key                 = "k8s.io/cluster/tf-argo-cluster"
    value               = "owned"
    propagate_at_launch = true
  }

  depends_on = [aws_launch_template.eks_worker]

  lifecycle {
    ignore_changes = [desired_capacity]
  }
}
