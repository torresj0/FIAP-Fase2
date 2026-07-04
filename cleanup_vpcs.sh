#!/usr/bin/env bash
set -euo pipefail

REGION="${AWS_REGION:-us-east-2}"
KEEP_VPC="${KEEP_VPC:-insira_sua_vpc_aqui}"

for VPC_ID in vpc-0eb127225a17aa70d vpc-057a937d1b87eb58e; do
  echo ""
  echo "🗑️  Cleaning VPC $VPC_ID ..."

  # --- Internet Gateways ---
  IGW_IDS=$(aws ec2 describe-internet-gateways \
    --region "$REGION" \
    --filters "Name=attachment.vpc-id,Values=$VPC_ID" \
    --query "InternetGateways[].InternetGatewayId" \
    --output text)
  for IGW_ID in $IGW_IDS; do
    echo "  ↳ Detaching IGW $IGW_ID"
    aws ec2 detach-internet-gateway --region "$REGION" --internet-gateway-id "$IGW_ID" --vpc-id "$VPC_ID"
    echo "  ↳ Deleting IGW $IGW_ID"
    aws ec2 delete-internet-gateway --region "$REGION" --internet-gateway-id "$IGW_ID"
  done

  # --- Subnets ---
  SUBNET_IDS=$(aws ec2 describe-subnets \
    --region "$REGION" \
    --filters "Name=vpc-id,Values=$VPC_ID" \
    --query "Subnets[].SubnetId" \
    --output text)
  for SUBNET_ID in $SUBNET_IDS; do
    echo "  ↳ Deleting subnet $SUBNET_ID"
    aws ec2 delete-subnet --region "$REGION" --subnet-id "$SUBNET_ID"
  done

  # --- Non-default Route Tables ---
  ALL_RTBS=$(aws ec2 describe-route-tables \
    --region "$REGION" \
    --filters "Name=vpc-id,Values=$VPC_ID" \
    --query "RouteTables[].RouteTableId" \
    --output text)
  MAIN_RTB=$(aws ec2 describe-route-tables \
    --region "$REGION" \
    --filters "Name=vpc-id,Values=$VPC_ID" "Name=association.main,Values=true" \
    --query "RouteTables[].RouteTableId" \
    --output text)
  for RTB_ID in $ALL_RTBS; do
    if [ "$RTB_ID" != "$MAIN_RTB" ]; then
      echo "  ↳ Deleting route table $RTB_ID"
      aws ec2 delete-route-table --region "$REGION" --route-table-id "$RTB_ID" || true
    fi
  done

  # --- Non-default Security Groups ---
  SG_IDS=$(aws ec2 describe-security-groups \
    --region "$REGION" \
    --filters "Name=vpc-id,Values=$VPC_ID" \
    --query "SecurityGroups[?GroupName!='default'].GroupId" \
    --output text)
  for SG_ID in $SG_IDS; do
    echo "  ↳ Deleting security group $SG_ID"
    aws ec2 delete-security-group --region "$REGION" --group-id "$SG_ID" || true
  done

  # --- VPC ---
  echo "  ↳ Deleting VPC $VPC_ID"
  aws ec2 delete-vpc --region "$REGION" --vpc-id "$VPC_ID" \
    && echo "  ✅ VPC $VPC_ID deleted" \
    || echo "  ❌ Failed to delete VPC $VPC_ID — check for remaining dependencies"
done

echo ""
echo "=== Final VPC list ==="
aws ec2 describe-vpcs \
  --region "$REGION" \
  --query "Vpcs[].{Id:VpcId,Name:Tags[?Key=='Name'].Value|[0]}" \
  --output table
