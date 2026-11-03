provider "aws" {
  region = var.region
}


resource "aws_vpc" "lab_vpc" {
  cidr_block = "10.20.0.0/16"
  enable_dns_hostnames = true
  tags = {
    Name = "lab-vpc"
  }
}  

resource "aws_subnet" "lab_subnet" {
vpc_id = aws_vpc.lab_vpc.id
cidr_block = "10.20.1.0/24"
availability_zone = "eu-north-1a"
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
    from_port        = 22 // SSH
    to_port          = 22
    protocol         = "tcp"
    cidr_blocks      = [var.admin_cidr]
    description = "SSH access"
  }
  ingress {
    from_port        = 80 // Nginx
    to_port          = 80
    protocol         = "tcp"
    cidr_blocks      = ["0.0.0.0/0"]
  }

  ingress {
    from_port        = 443 // HTTPS
    to_port          = 443
    protocol         = "tcp"
    cidr_blocks      = ["0.0.0.0/0"]
  }

  egress {
    from_port        = 0 
    to_port          = 0
    protocol         = "-1"
    cidr_blocks      = ["0.0.0.0/0"]
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
  ami                    = var.ami
  instance_type          = var.instance_type
  key_name               = aws_key_pair.lab_key.key_name
  vpc_security_group_ids = [aws_security_group.lab-sg.id]
  subnet_id = aws_subnet.lab_subnet.id
  iam_instance_profile = aws_iam_instance_profile.lab_profile.name
  root_block_device {
    encrypted = true
    volume_type = "gp3"
    volume_size = 20
  }
  metadata_options{
    http_endpoint = "enabled"
    http_tokens = "required"
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
  encrypted = true
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
  instance = aws_instance.lab_ec2.id
  domain   = "vpc"
  depends_on = [ aws_internet_gateway.lab_gw ]
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
  "Version":"2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Action": [
      "kms:Encrypt",
      "kms:Decrypt",
      "kms:DescribeKey"
    ],
    "Resource": aws_kms_key.lab_kms_key.arn
}]
})
}
