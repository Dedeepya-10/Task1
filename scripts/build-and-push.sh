#!/usr/bin/env bash
# Build the Docker image and push it to an AWS ECR repository.
#
# Usage:
#   ./scripts/build-and-push.sh <aws-region> <ecr-repo-name> [tag]
#
# Example:
#   ./scripts/build-and-push.sh us-east-1 devops-task-app latest
set -euo pipefail

AWS_REGION="${1:?Usage: $0 <aws-region> <ecr-repo-name> [tag]}"
REPO_NAME="${2:?Usage: $0 <aws-region> <ecr-repo-name> [tag]}"
TAG="${3:-latest}"

ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
REGISTRY="${ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"
IMAGE_URI="${REGISTRY}/${REPO_NAME}:${TAG}"

echo "==> Ensuring ECR repository '${REPO_NAME}' exists in ${AWS_REGION}"
aws ecr describe-repositories --repository-names "${REPO_NAME}" --region "${AWS_REGION}" >/dev/null 2>&1 \
  || aws ecr create-repository --repository-name "${REPO_NAME}" --region "${AWS_REGION}"

echo "==> Logging in to ECR registry ${REGISTRY}"
aws ecr get-login-password --region "${AWS_REGION}" \
  | docker login --username AWS --password-stdin "${REGISTRY}"

echo "==> Building and pushing image ${IMAGE_URI} for linux/amd64"
# Target linux/amd64 explicitly: the EC2 instance (t3.micro on the standard
# Amazon Linux 2023 AMI) is x86_64, but a plain `docker build` on Apple
# Silicon produces an arm64 image, which fails on the instance with
# "exec format error". buildx --platform makes this build reproducible
# regardless of the host architecture running this script.
docker buildx build --platform linux/amd64 -t "${IMAGE_URI}" --push .

echo "==> Done. Image URI: ${IMAGE_URI}"
