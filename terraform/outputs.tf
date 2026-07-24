output "instance_id" {
  description = "ID of the EC2 instance"
  value       = aws_instance.app_server.id
}

output "instance_public_ip" {
  description = "Public IP address of the EC2 instance"
  value       = aws_instance.app_server.public_ip
}

output "instance_public_dns" {
  description = "Public DNS name of the EC2 instance"
  value       = aws_instance.app_server.public_dns
}

output "security_group_id" {
  description = "ID of the security group attached to the instance"
  value       = aws_security_group.app.id
}

output "app_url" {
  description = "URL to reach the running application"
  value       = "http://${aws_instance.app_server.public_ip}:${var.host_port}"
}

output "ssh_key_name" {
  description = "Name of the EC2 key pair Terraform generated"
  value       = aws_key_pair.generated.key_name
}

output "ssh_private_key_pem" {
  description = "Private half of the generated SSH key pair. Copy this into the EC2_SSH_KEY GitHub Secret (terraform output -raw ssh_private_key_pem). Not printed by default since it's marked sensitive."
  value       = tls_private_key.ssh.private_key_pem
  sensitive   = true
}
