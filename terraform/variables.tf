# ---------------------------------------------------------------------------
# Provider / region
# ---------------------------------------------------------------------------

variable "aws_region" {
  description = "AWS region to deploy resources into"
  type        = string
  default     = "us-east-1"
}

# ---------------------------------------------------------------------------
# EC2 instance configuration
# ---------------------------------------------------------------------------

variable "instance_type" {
  description = "EC2 instance type (kept on the AWS free tier by default)"
  type        = string
  default     = "t3.micro"
}

variable "key_name" {
  description = "Name of an existing EC2 key pair to attach for SSH access. Leave empty to skip attaching a key pair (you won't be able to SSH in)."
  type        = string
  default     = ""
}

variable "allowed_ssh_cidr" {
  description = "CIDR block allowed to SSH into the instance on port 22. Restrict this to your own IP (e.g. 1.2.3.4/32) instead of leaving it open to the world."
  type        = string
  default     = "0.0.0.0/0"
}

# ---------------------------------------------------------------------------
# Application / container configuration
# ---------------------------------------------------------------------------

variable "ecr_repository_url" {
  description = "Full ECR repository URL to pull the app image from, e.g. 123456789012.dkr.ecr.us-east-1.amazonaws.com/devops-task-app"
  type        = string
}

variable "app_image_tag" {
  description = "Docker image tag to deploy"
  type        = string
  default     = "latest"
}

variable "container_port" {
  description = "Port the Node.js app listens on inside the container"
  type        = number
  default     = 3000
}

variable "host_port" {
  description = "Port on the EC2 host to map to the container (80 so the app is reachable without specifying a port)"
  type        = number
  default     = 80
}

variable "project_name" {
  description = "Name prefix used to tag/name all resources"
  type        = string
  default     = "devops-task"
}
