#!/bin/bash

set -e

# 0. terraform, docker, npm and aws utilities must be installed
for cmd in aws terraform docker npm; do
  command -v $cmd &>/dev/null || { echo "ERROR: $cmd is not installed or not in PATH"; exit 1; }
done

echo "========> Starting deployment..."

# 1. Terraform init & apply
echo "====> Applying Terraform..."

terraform init
terraform apply -auto-approve

# get outputs
REGION=$(terraform output -raw region)
IMAGE_NAME=$(terraform output -raw image_name)
ECR_URL=$(terraform output -raw ecr_repository_url)
CLUSTER_NAME=$(terraform output -raw ecs_cluster_name)
SERVICE_NAME=$(terraform output -raw ecs_service_name)
CLOUDFRONT_ENTRYPOINT=$(terraform output -raw cloudfront_domain)
FRONTEND_BUCKET_URL=$(terraform output -raw frontend_bucket_url)
RDS_MASTER_PASSWORD=$(terraform output -raw rds_master_password)

# 2. Build Docker image and provision it to the ECR

echo "========> Building and publishing the app image..."

# Build the image
echo "====> Building Docker image..."
docker build -t "$IMAGE_NAME" ./app

# Login to ECR
echo "====> Logging into ECR..."
aws ecr get-login-password --region "$REGION" \
| docker login --username AWS --password-stdin $(echo $ECR_URL | cut -d'/' -f1)

# Tag image
echo "====> Tagging image..."
docker tag "$IMAGE_NAME:latest" "$ECR_URL:latest"

# Push image
echo "====> Pushing image..."
docker push "$ECR_URL":latest

# Force ECS deployment
echo "====> Updating ECS with new image..."
aws ecs update-service \
  --cluster "$CLUSTER_NAME" \
  --service "$SERVICE_NAME" \
  --force-new-deployment \
  --region "$REGION" \
  --no-cli-pager

# 3. Build and provision the frontend static files to s3
cd ./frontend 
npm install
npm run build 

# sync aws account with the s3
aws s3 sync \
  ./dist \
  "$FRONTEND_BUCKET_URL" \
  --sse AES256 \
  --delete

echo "Deployment complete! Container is being updated with the new image. This can take a couple minutes. Connect to https://$CLOUDFRONT_ENTRYPOINT"