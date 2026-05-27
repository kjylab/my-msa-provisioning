resource "aws_vpc" "kt-cloud-vpc" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true
}

resource "aws_internet_gateway" "main_igw" {
  vpc_id = aws_vpc.kt-cloud-vpc.id
}

resource "aws_eip" "nlb_eip_2a" {
  domain = "vpc"
}

resource "aws_eip" "nlb_eip_2b" {
  domain = "vpc"
}

resource "aws_lb" "kt-cloud-nlb" {
  name               = "kt-cloud-nlb"
  internal           = false
  load_balancer_type = "network"

  subnet_mapping {
    subnet_id     = aws_subnet.public-ap-northeast-2a.id
    allocation_id = aws_eip.nlb_eip_2a.id
  }

  subnet_mapping {
    subnet_id     = aws_subnet.public-ap-northeast-2b.id
    allocation_id = aws_eip.nlb_eip_2b.id
  }
}

resource "aws_lb_target_group" "k8s-api-tg" {
  name     = "k8s-api-tg"
  port     = 6443
  protocol = "TCP"
  vpc_id   = aws_vpc.kt-cloud-vpc.id

  health_check {
    protocol = "TCP"
    port     = "6443"
    interval = 10
  }
}

resource "aws_lb_listener" "k8s-api-listener" {
  load_balancer_arn = aws_lb.kt-cloud-nlb.arn
  port              = 6443
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.k8s-api-tg.arn
  }
}

resource "aws_lb_target_group_attachment" "ap-northeast-2a-master-node-01-attach" {
  target_group_arn = aws_lb_target_group.k8s-api-tg.arn
  target_id        = aws_instance.ap-northeast-2a-master-node-01.id
  port             = 6443
}

resource "aws_lb_target_group_attachment" "ap-northeast-2a-master-node-02-attach" {
  target_group_arn = aws_lb_target_group.k8s-api-tg.arn
  target_id        = aws_instance.ap-northeast-2a-master-node-02.id
  port             = 6443
}

resource "aws_lb_target_group_attachment" "ap-northeast-2b-master-node-01-attach" {
  target_group_arn = aws_lb_target_group.k8s-api-tg.arn
  target_id        = aws_instance.ap-northeast-2b-master-node-01.id
  port             = 6443
}

resource "aws_route_table" "kt-cloud-public-rt" {
  vpc_id = aws_vpc.kt-cloud-vpc.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main_igw.id
  }
}

resource "aws_security_group" "cluster-node-sg" {
  name   = "cluster-node-sg"
  vpc_id = aws_vpc.kt-cloud-vpc.id

  ingress {
    from_port   = 0
    to_port     = 65535
    protocol    = "tcp"
    cidr_blocks = [aws_vpc.kt-cloud-vpc.cidr_block]
  }

  ingress {
    from_port   = 0
    to_port     = 65535
    protocol    = "udp"
    cidr_blocks = [aws_vpc.kt-cloud-vpc.cidr_block]
  }

  ingress {
    from_port   = -1
    to_port     = -1
    protocol    = "icmp"
    cidr_blocks = [aws_vpc.kt-cloud-vpc.cidr_block]
  }

  # Calico IPIP (protocol 4) cross-node pod traffic: self-referential rule
  ingress {
    from_port = 0
    to_port   = 0
    protocol  = "-1"
    self      = true
  }

  ingress {
    from_port       = 22
    to_port         = 22
    protocol        = "tcp"
    security_groups = [aws_security_group.bastion-node-sg.id]
  }

  ingress {
    from_port   = 6443
    to_port     = 6443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # NLB → Traefik NodePort (클라이언트 IP 보존으로 인터넷에서 직접 들어옴)
  ingress {
    from_port   = 31896
    to_port     = 31897
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}


# Traefik HTTP ingress: NLB port 80 → worker NodePort 31896
resource "aws_lb_target_group" "traefik-http-tg" {
  name     = "traefik-http-tg"
  port     = 31896
  protocol = "TCP"
  vpc_id   = aws_vpc.kt-cloud-vpc.id

  health_check {
    protocol = "TCP"
    port     = "31896"
    interval = 10
  }
}

resource "aws_lb_listener" "traefik-http-listener" {
  load_balancer_arn = aws_lb.kt-cloud-nlb.arn
  port              = 80
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.traefik-http-tg.arn
  }
}

resource "aws_lb_target_group_attachment" "traefik-2a-worker-attach" {
  target_group_arn = aws_lb_target_group.traefik-http-tg.arn
  target_id        = aws_instance.ap-northeast-2a-worker-node-01.id
  port             = 31896
}

resource "aws_lb_target_group_attachment" "traefik-2b-worker-01-attach" {
  target_group_arn = aws_lb_target_group.traefik-http-tg.arn
  target_id        = aws_instance.ap-northeast-2b-worker-node-01.id
  port             = 31896
}

resource "aws_lb_target_group_attachment" "traefik-2b-worker-02-attach" {
  target_group_arn = aws_lb_target_group.traefik-http-tg.arn
  target_id        = aws_instance.ap-northeast-2b-worker-node-02.id
  port             = 31896
}

data "http" "my_ip" {
  url = "https://ifconfig.me/ip"
}

locals {
  my_ip_cidr = "${chomp(data.http.my_ip.response_body)}/32"
}

resource "aws_security_group" "bastion-node-sg" {
  name   = "bastion-node-sg"
  vpc_id = aws_vpc.kt-cloud-vpc.id

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [local.my_ip_cidr]
  }

  ingress {
    from_port   = -1
    to_port     = -1
    protocol    = "icmp"
    cidr_blocks = [local.my_ip_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}
