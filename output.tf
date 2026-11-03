output "server_ip" {
  description = "EIP"
  value       = aws_eip.lab_eip.public_ip
}