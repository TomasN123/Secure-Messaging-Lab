provider "aws" {
  region = var.region
}

resource "aws_instance" "Monitoring" {
  ami                    = var.ami
  instance_type          = var.instance_type
  key_name               = aws_key_pair.deployer.key_name

  tags = {
    Name = "Terraform-EC2"
  }
}