variable "rabbitmq_password" {
  type        = string
  description = "psw of the rabbit account used by vault"
  sensitive   = true
}