variable "region" {
  type        = string
  description = "AWS Region"
  default     = "eu-north-1"
}

variable "instance_type" {
  type        = string
  description = "EC2 instance"
  default     = "t3.small"
}

variable "ami" {
  type        = string
  description = "AMI of EC2"
  default     = "ami-01e082ac2f79f3918"
}

variable "domain_name" {
  type        = string
  description = "Domain name"
  default     = "cloud-telemetry.click"
}

variable "email" {
  type        = string
  description = "Email for SNS"
  default     = "3novotnytomas@gmail.com"
}
