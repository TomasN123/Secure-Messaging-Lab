variable "region" {
  type        = string
  description = "AWS Region"
  default     = "eu-north-1"
}

variable "instance_type" {
  type        = string
  description = "EC2 instance"
  default     = "t3.large"
}

variable "ami" {
  type        = string
  description = "AMI of EC2"
  default     = "ami-048b204bd75ee6fdd"
}

variable "domain_name" {
  type        = string
  description = "Domain name"
  default     = "cloud-telemetry.click"
}

variable "email" {
  type        = string
  description = "Email"
  default     = "3novotnytomas@gmail.com"
}
variable "admin_cidr" {
  type        = string
  description = "IP for port 22"
}
