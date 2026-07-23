#!/bin/bash
set -euxo pipefail

# Install Docker (Amazon Linux 2023 ships it via the "docker" package)
dnf update -y
dnf install -y docker
systemctl enable --now docker
usermod -aG docker ec2-user

# Authenticate to ECR using the instance's IAM role (no static credentials
# needed - see the aws_iam_instance_profile attached in main.tf)
aws ecr get-login-password --region "${aws_region}" \
  | docker login --username AWS --password-stdin "${ecr_registry}"

# Pull and run the application container
docker pull "${ecr_repository_url}:${app_image_tag}"

docker run -d \
  --name app \
  --restart unless-stopped \
  -p ${host_port}:${container_port} \
  "${ecr_repository_url}:${app_image_tag}"
