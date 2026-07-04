#!/usr/bin/env bash
# build-and-push.sh
# Builds all 5 Docker images and pushes them to ECR
set -euo pipefail

REGION="${AWS_REGION:-us-east-2}"
ACCOUNT_ID=$(aws sts get-caller-identity --query "Account" --output text 2>/dev/null || echo "SEU_ACCOUNT_ID_AQUI")
ECR_BASE="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com"
PROJECT_DIR="$(pwd)"

echo ""
echo "╔══════════════════════════════════════════════════════╗"
echo "║   ToggleMaster — Build & Push to ECR                 ║"
echo "╚══════════════════════════════════════════════════════╝"
echo ""

# Authenticate Docker with ECR
echo "🔐 Logging in to ECR..."
aws ecr get-login-password --region "$REGION" | \
  docker login --username AWS --password-stdin "$ECR_BASE"
echo "✅ ECR login successful"
echo ""

# Build and push each service
SERVICES=(
  "auth-service:8001"
  "flag-service:8002"
  "targeting-service:8003"
  "evaluation-service:8004"
  "analytics-service:8005"
)

for ENTRY in "${SERVICES[@]}"; do
  SVC="${ENTRY%%:*}"
  PORT="${ENTRY##*:}"
  IMAGE_URI="${ECR_BASE}/${SVC}:latest"

  echo "🔨 Building ${SVC}..."
  docker build \
    --platform linux/amd64 \
    -t "${SVC}:latest" \
    -t "${IMAGE_URI}" \
    "${PROJECT_DIR}/${SVC}"

  echo "📤 Pushing ${SVC} to ECR..."
  docker push "${IMAGE_URI}"
  echo "  ✅ ${SVC} → ${IMAGE_URI}"
  echo ""
done

echo "╔══════════════════════════════════════════════════════╗"
echo "║   All images pushed to ECR ✅                         ║"
echo "╠══════════════════════════════════════════════════════╣"
for ENTRY in "${SERVICES[@]}"; do
  SVC="${ENTRY%%:*}"
  echo "║  ${ECR_BASE}/${SVC}:latest"
done
echo "╚══════════════════════════════════════════════════════╝"
