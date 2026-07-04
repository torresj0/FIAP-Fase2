#!/usr/bin/env bash
# provision-aws-services.sh
# Creates all AWS managed services needed for the ToggleMaster platform
set -euo pipefail

REGION="${AWS_REGION:-us-east-2}"
ACCOUNT_ID=$(aws sts get-caller-identity --query "Account" --output text)
VPC_ID="${VPC_ID:-insira_sua_vpc_aqui}"
DB_PASSWORD="${DB_PASSWORD:-ToggleMaster2024!}"   # Set via environment variable

echo ""
echo "╔══════════════════════════════════════════════════════╗"
echo "║   ToggleMaster — AWS Services Provisioner            ║"
echo "║   Account: $ACCOUNT_ID   Region: $REGION             ║"
echo "╚══════════════════════════════════════════════════════╝"
echo ""

# ─── 1. ECR REPOSITORIES ──────────────────────────────────────────────────────
echo "📦 [1/6] Creating ECR repositories..."
for SVC in auth-service flag-service targeting-service evaluation-service analytics-service; do
  URI=$(aws ecr describe-repositories --region "$REGION" \
    --repository-names "$SVC" \
    --query "repositories[0].repositoryUri" \
    --output text 2>/dev/null) || URI=""
  if [ -z "$URI" ] || [ "$URI" = "None" ]; then
    URI=$(aws ecr create-repository --region "$REGION" \
      --repository-name "$SVC" \
      --image-scanning-configuration scanOnPush=true \
      --query "repository.repositoryUri" --output text)
    echo "  ✅ Created ECR repo: $URI"
  else
    echo "  ⏭️  ECR repo already exists: $URI"
  fi
done
echo ""

# ─── 2. RDS SUBNET GROUP ──────────────────────────────────────────────────────
echo "🗄️  [2/6] Setting up RDS subnet group..."
# Use private subnets for RDS
PRIVATE_SUBNETS="subnet-0202dfa4fc1d6ce3a subnet-080902e2ed7393ae7 subnet-08747daab22eec078"

aws rds describe-db-subnet-groups \
  --region "$REGION" \
  --db-subnet-group-name togglemaster-subnet-group \
  --query "DBSubnetGroups[0].DBSubnetGroupName" \
  --output text 2>/dev/null || \
aws rds create-db-subnet-group \
  --region "$REGION" \
  --db-subnet-group-name togglemaster-subnet-group \
  --db-subnet-group-description "ToggleMaster RDS subnet group" \
  --subnet-ids $PRIVATE_SUBNETS \
  --output text > /dev/null && echo "  ✅ RDS subnet group ready"

# RDS Security Group
RDS_SG=$(aws ec2 describe-security-groups --region "$REGION" \
  --filters "Name=vpc-id,Values=$VPC_ID" "Name=group-name,Values=togglemaster-rds-sg" \
  --query "SecurityGroups[0].GroupId" --output text 2>/dev/null)
if [ -z "$RDS_SG" ] || [ "$RDS_SG" = "None" ]; then
  RDS_SG=$(aws ec2 create-security-group --region "$REGION" \
    --group-name togglemaster-rds-sg \
    --description "ToggleMaster RDS security group" \
    --vpc-id "$VPC_ID" \
    --query "GroupId" --output text)
  aws ec2 authorize-security-group-ingress --region "$REGION" \
    --group-id "$RDS_SG" \
    --protocol tcp --port 5432 --cidr 10.0.0.0/16
  echo "  ✅ RDS security group created: $RDS_SG"
else
  echo "  ⏭️  RDS security group exists: $RDS_SG"
fi

# ─── 3. RDS POSTGRESQL INSTANCES ─────────────────────────────────────────────
echo ""
echo "🗄️  [3/6] Creating RDS PostgreSQL instances (this takes ~5 min each, running async)..."
for DB in auth-service flag-service targeting-service; do
  DB_ID="togglemaster-${DB%-service}"  # e.g. togglemaster-auth
  DB_NAME="${DB%-service}db"           # e.g. authdb

  EXISTS=$(aws rds describe-db-instances --region "$REGION" \
    --db-instance-identifier "$DB_ID" \
    --query "DBInstances[0].DBInstanceStatus" \
    --output text 2>/dev/null || echo "notfound")

  if [ "$EXISTS" = "notfound" ]; then
    aws rds create-db-instance \
      --region "$REGION" \
      --db-instance-identifier "$DB_ID" \
      --db-instance-class db.t3.micro \
      --engine postgres \
      --engine-version "15.7" \
      --master-username postgres \
      --master-user-password "$DB_PASSWORD" \
      --db-name "$DB_NAME" \
      --allocated-storage 20 \
      --storage-type gp2 \
      --vpc-security-group-ids "$RDS_SG" \
      --db-subnet-group-name togglemaster-subnet-group \
      --no-publicly-accessible \
      --no-multi-az \
      --backup-retention-period 0 \
      --no-deletion-protection \
      --output text > /dev/null
    echo "  🚀 RDS $DB_ID creation initiated (will be ready in ~5 min)"
  else
    echo "  ⏭️  RDS $DB_ID already exists (status: $EXISTS)"
  fi
done
echo ""

# ─── 4. ELASTICACHE REDIS ─────────────────────────────────────────────────────
echo "⚡ [4/6] Creating ElastiCache Redis cluster..."
REDIS_SG=$(aws ec2 describe-security-groups --region "$REGION" \
  --filters "Name=vpc-id,Values=$VPC_ID" "Name=group-name,Values=togglemaster-redis-sg" \
  --query "SecurityGroups[0].GroupId" --output text 2>/dev/null)
if [ -z "$REDIS_SG" ] || [ "$REDIS_SG" = "None" ]; then
  REDIS_SG=$(aws ec2 create-security-group --region "$REGION" \
    --group-name togglemaster-redis-sg \
    --description "ToggleMaster Redis security group" \
    --vpc-id "$VPC_ID" \
    --query "GroupId" --output text)
  aws ec2 authorize-security-group-ingress --region "$REGION" \
    --group-id "$REDIS_SG" \
    --protocol tcp --port 6379 --cidr 10.0.0.0/16
fi

# ElastiCache subnet group
aws elasticache describe-cache-subnet-groups \
  --region "$REGION" \
  --cache-subnet-group-name togglemaster-redis-subnet \
  --query "CacheSubnetGroups[0].CacheSubnetGroupName" \
  --output text 2>/dev/null || \
aws elasticache create-cache-subnet-group \
  --region "$REGION" \
  --cache-subnet-group-name togglemaster-redis-subnet \
  --cache-subnet-group-description "ToggleMaster Redis subnet group" \
  --subnet-ids subnet-0202dfa4fc1d6ce3a subnet-080902e2ed7393ae7 subnet-08747daab22eec078 \
  --output text > /dev/null

EXISTS=$(aws elasticache describe-cache-clusters --region "$REGION" \
  --cache-cluster-id togglemaster-redis \
  --query "CacheClusters[0].CacheClusterStatus" \
  --output text 2>/dev/null || echo "notfound")

if [ "$EXISTS" = "notfound" ]; then
  aws elasticache create-cache-cluster \
    --region "$REGION" \
    --cache-cluster-id togglemaster-redis \
    --cache-node-type cache.t3.micro \
    --engine redis \
    --engine-version "7.1" \
    --num-cache-nodes 1 \
    --cache-subnet-group-name togglemaster-redis-subnet \
    --security-group-ids "$REDIS_SG" \
    --output text > /dev/null
  echo "  🚀 ElastiCache Redis creation initiated (will be ready in ~3 min)"
else
  echo "  ⏭️  ElastiCache Redis already exists (status: $EXISTS)"
fi
echo ""

# ─── 5. DYNAMODB TABLE ────────────────────────────────────────────────────────
echo "📊 [5/6] Creating DynamoDB table..."
EXISTS=$(aws dynamodb describe-table --region "$REGION" \
  --table-name ToggleMasterAnalytics \
  --query "Table.TableStatus" --output text 2>/dev/null || echo "notfound")

if [ "$EXISTS" = "notfound" ]; then
  aws dynamodb create-table \
    --region "$REGION" \
    --table-name ToggleMasterAnalytics \
    --attribute-definitions AttributeName=event_id,AttributeType=S \
    --key-schema AttributeName=event_id,KeyType=HASH \
    --billing-mode PAY_PER_REQUEST \
    --output text > /dev/null
  echo "  ✅ DynamoDB table ToggleMasterAnalytics created"
else
  echo "  ⏭️  DynamoDB table already exists (status: $EXISTS)"
fi
echo ""

# ─── 6. SQS QUEUE ─────────────────────────────────────────────────────────────
echo "📬 [6/6] Creating SQS queue..."
SQS_URL=$(aws sqs get-queue-url --region "$REGION" \
  --queue-name togglemaster-events \
  --query "QueueUrl" --output text 2>/dev/null || echo "notfound")

if [ "$SQS_URL" = "notfound" ]; then
  SQS_URL=$(aws sqs create-queue \
    --region "$REGION" \
    --queue-name togglemaster-events \
    --attributes VisibilityTimeout=30,MessageRetentionPeriod=86400 \
    --query "QueueUrl" --output text)
  echo "  ✅ SQS queue created: $SQS_URL"
else
  echo "  ⏭️  SQS queue already exists: $SQS_URL"
fi
SQS_ARN=$(aws sqs get-queue-attributes --region "$REGION" \
  --queue-url "$SQS_URL" \
  --attribute-names QueueArn \
  --query "Attributes.QueueArn" --output text)
echo ""

# ─── SUMMARY ──────────────────────────────────────────────────────────────────
echo "╔══════════════════════════════════════════════════════════════════╗"
echo "║                    PROVISIONING SUMMARY                         ║"
echo "╠══════════════════════════════════════════════════════════════════╣"
echo "║  ECR Base URI : $ACCOUNT_ID.dkr.ecr.$REGION.amazonaws.com"
echo "║  SQS URL      : $SQS_URL"
echo "║  SQS ARN      : $SQS_ARN"
echo "║  DynamoDB     : ToggleMasterAnalytics (us-east-2)"
echo "║  RDS Password : $DB_PASSWORD"
echo "╠══════════════════════════════════════════════════════════════════╣"
echo "║  NOTE: RDS & ElastiCache are still creating (~5 min)."
echo "║  Run check-endpoints.sh after ~5 min to get all connection URLs. ║"
echo "╚══════════════════════════════════════════════════════════════════╝"
