provider "aws" {
  region = var.region
}


resource "aws_vpc" "lab_vpc" {
  cidr_block           = "10.20.0.0/16"
  enable_dns_hostnames = true
  tags = {
    Name = "lab-vpc"
  }
}

resource "aws_subnet" "lab_subnet" {
  vpc_id                  = aws_vpc.lab_vpc.id
  cidr_block              = "10.20.1.0/24"
  availability_zone       = "eu-north-1a"
  map_public_ip_on_launch = true
  tags = {
    Name = "lab-subnet"
  }
}

resource "aws_internet_gateway" "lab_gw" {
  vpc_id = aws_vpc.lab_vpc.id

  tags = {
    Name = "lab-gw"
  }
}

resource "aws_route_table" "lab_route" {
  vpc_id = aws_vpc.lab_vpc.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.lab_gw.id
  }

  tags = {
    Name = "lab-route"
  }
}

resource "aws_route_table_association" "lab_table" {
  subnet_id      = aws_subnet.lab_subnet.id
  route_table_id = aws_route_table.lab_route.id
}

resource "aws_security_group" "lab-sg" {
  name        = "lab-sg"
  description = "SG for my messaging lab project"
  vpc_id      = aws_vpc.lab_vpc.id
  ingress {
    from_port   = 22 // SSH
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.admin_cidr]
    description = "SSH access"
  }
  ingress {
    from_port   = 80 // HTTP
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 443 // HTTPS
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

  tags = {
    Name = "lab-sg"
  }
}

resource "aws_key_pair" "lab_key" {
  key_name   = "lab_key"
  public_key = file(pathexpand("~/.ssh/aws-lab.pub"))
}


resource "aws_instance" "lab_ec2" {
  ami                         = var.ami
  instance_type               = var.instance_type
  key_name                    = aws_key_pair.lab_key.key_name
  vpc_security_group_ids      = [aws_security_group.lab-sg.id]
  subnet_id                   = aws_subnet.lab_subnet.id
  iam_instance_profile        = aws_iam_instance_profile.lab_profile.name
  user_data_replace_on_change = true

  user_data = <<EOF
#! /bin/bash
sudo dnf update -y
sudo dnf install -y docker
sudo systemctl start docker
sudo systemctl enable docker
sudo curl -L "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
sudo chmod +x /usr/local/bin/docker-compose
EOF

  root_block_device {
    encrypted   = true
    volume_type = "gp3"
    volume_size = 20
  }
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
  }


  tags = {
    Name = "lab-EC2"
  }
}

resource "aws_ebs_volume" "lab_ebs" {
  availability_zone = aws_instance.lab_ec2.availability_zone
  size              = 20
  type              = "gp3"
  encrypted         = true
  tags = {
    Name = "lab_ebs"
  }
}

resource "aws_volume_attachment" "lab_ebs_attachment" {
  device_name = "/dev/sdf"
  volume_id   = aws_ebs_volume.lab_ebs.id
  instance_id = aws_instance.lab_ec2.id
}

resource "aws_eip" "lab_eip" {
  instance   = aws_instance.lab_ec2.id
  domain     = "vpc"
  depends_on = [aws_internet_gateway.lab_gw]
}



data "aws_iam_policy_document" "ec2_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "lab_role" {
  name               = "lab_role"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.lab_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "lab_profile" {
  name = "lab-ec2-profile"
  role = aws_iam_role.lab_role.name
}

resource "aws_kms_key" "lab_kms_key" {
  description             = "KMS key"
  enable_key_rotation     = true
  deletion_window_in_days = 7
}

resource "aws_kms_alias" "lab_kms_alias" {
  name          = "alias/lab_alias"
  target_key_id = aws_kms_key.lab_kms_key.key_id
}

resource "aws_iam_role_policy" "lab_kms_policy" {
  name = "lab_kms_policy"
  role = aws_iam_role.lab_role.id

  policy = jsonencode({
    "Version" : "2012-10-17",
    "Statement" : [{
      "Effect" : "Allow",
      "Action" : [
        "kms:Encrypt",
        "kms:Decrypt",
        "kms:DescribeKey"
      ],
      "Resource" : aws_kms_key.lab_kms_key.arn
    }]
  })
}

resource "terraform_data" "deploy" {
  triggers_replace = [
    aws_instance.lab_ec2.id,
    aws_volume_attachment.lab_ebs_attachment.id
  ]

  connection {
    type        = "ssh"
    user        = "ec2-user"
    private_key = file(pathexpand("~/.ssh/aws-lab"))
    host        = aws_eip.lab_eip.public_ip
  }

  provisioner "remote-exec" {
    inline = [

      <<-EOT
      for i in $(seq 1 60); do
        if [ -b /dev/xvdf ] || [ -b /dev/sdf ]; then
          break
        fi
        sleep 2
      done

      if [ ! -b /dev/xvdf ] && [ ! -b /dev/sdf ]; then
        echo "EBS device not found"
        exit 1
      fi
      EOT
      ,

      "DEVICE=$([ -b /dev/xvdf ] && echo /dev/xvdf || echo /dev/sdf)",

      # Format only if filesystem does not exist
      "if ! sudo blkid $DEVICE >/dev/null 2>&1; then sudo mkfs.xfs -f $DEVICE; fi",

      "sudo mkdir -p /data",

      # Get UUID
      "UUID=$(sudo blkid -s UUID -o value $DEVICE)",

      # Validate UUID
      "[ -n \"$UUID\" ] || { echo 'Unable to determine UUID'; exit 1; }",

      # Add fstab record only once
      "grep -q \"$UUID\" /etc/fstab || echo \"UUID=$UUID /data xfs defaults,nofail,nodev,nosuid 0 2\" | sudo tee -a /etc/fstab",

      # Mount filesystem
      "sudo mount -a",

      "sudo mkdir -p /data/traefik",
      "sudo mkdir -p /data/postgres",
      "sudo mkdir -p /data/vault",
      "sudo mkdir -p /data/vault-audit",
      "sudo chown 100:1000 /data/vault",
      "sudo chown 100:1000 /data/vault-audit",
      "sudo chmod 700 /data/traefik",

      # Wait for Docker (max 5 minutes)
      <<-EOT
      for i in $(seq 1 60); do
        if sudo docker info >/dev/null 2>&1; then
          break
        fi
        sleep 5
      done

      if ! sudo docker info >/dev/null 2>&1; then
        echo "Docker daemon not ready"
        exit 1
      fi
      EOT
      ,

      # Wait for Docker Compose (max 5 minutes)
      <<-EOT
      for i in $(seq 1 60); do
        if sudo /usr/local/bin/docker-compose version >/dev/null 2>&1; then
          break
        fi
        sleep 5
      done

      if ! sudo /usr/local/bin/docker-compose version >/dev/null 2>&1; then
        echo "docker-compose not available"
        exit 1
      fi
      EOT
      ,
      "sudo usermod -aG docker ec2-user"
    ]
  }

}



data "aws_route53_zone" "link" {
  name = var.domain_name
}

resource "aws_route53_record" "link_record" {
  for_each = toset(["traefik", "keycloak", "vault", "kafka", "rabbit"])
  name     = "${each.key}.${var.domain_name}"
  zone_id  = data.aws_route53_zone.link.zone_id
  type     = "A"
  ttl      = 60
  records  = [aws_eip.lab_eip.public_ip]
}


resource "terraform_data" "compose" {
  depends_on = [terraform_data.deploy]
  triggers_replace = [
    filesha256("${path.module}/docker/docker-compose.yaml"),
    filesha256("${path.module}/docker/traefik.yaml"),
    filesha256("${path.module}/docker/.env"),
    filesha256("${path.module}/docker/initdb.sh"),
    filesha256("${path.module}/docker/vault.hcl"),
    terraform_data.deploy.id

  ]

  connection {
    type        = "ssh"
    user        = "ec2-user"
    private_key = file(pathexpand("~/.ssh/aws-lab"))
    host        = aws_eip.lab_eip.public_ip
  }
  provisioner "file" {
    source      = "${path.module}/docker/docker-compose.yaml"
    destination = "/home/ec2-user/docker-compose.yaml"
  }

  provisioner "file" {
    source      = "${path.module}/docker/traefik.yaml"
    destination = "/home/ec2-user/traefik.yaml"
  }

  provisioner "file" {
    source      = "${path.module}/docker/.env"
    destination = "/home/ec2-user/.env"
  }
  provisioner "file" {
    source      = "${path.module}/docker/initdb.sh"
    destination = "/home/ec2-user/initdb.sh"
  }
  provisioner "file" {
    source      = "${path.module}/docker/vault.hcl"
    destination = "/home/ec2-user/vault.hcl"
  }  

  provisioner "remote-exec" {
    inline = [
      "sudo chmod 600 /home/ec2-user/.env",
      "sudo docker-compose up -d",
      "sudo docker-compose restart vault"
    ]
  }
}

