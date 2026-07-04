set -euo pipefail
    
    REGION="${AWS_REGION:-us-east-2}"
    KEEP_VPC="${KEEP_VPC:-insira_sua_vpc_aqui}"   # <-- VPC we want to retain
    
    # 1️⃣ List all VPCs in the region
    ALL_VPCS=$(aws ec2 describe-vpcs \
        --region "$REGION" \
        --query "Vpcs[].VpcId" \
        --output text)
    
    echo "⚙️  All VPCs found: $ALL_VPCS"
    echo "🔹 Keeping VPC: $KEEP_VPC"
    echo ""
    
    # Loop over each VPC and delete it if it is NOT the one we keep
    for VPC_ID in $ALL_VPCS; do
        if [[ "$VPC_ID" == "$KEEP_VPC" ]]; then
            echo "✅ Skipping keep‑VPC $VPC_ID"
            continue
        fi
    
        echo "🗑️  Deleting VPC $VPC_ID …"
    
        # --- Detach & delete Internet Gateways ---
        for IGW_ID in $(aws ec2 describe-internet-gateways \
            --filters Name=attachment.vpc-id,Values=$VPC_ID \
            --query "InternetGateways[].InternetGatewayId" --output text); do
    
            echo "   ↳ Detaching IGW $IGW_ID from $VPC_ID"
            aws ec2 detach-internet-gateway --internet-gateway-id $IGW_ID --vpc-id $VPC_ID
            echo "   ↳ Deleting IGW $IGW_ID"
            aws ec2 delete-internet-gateway --internet-gateway-id $IGW_ID
        done

        # --- Delete NAT Gateways (if any) ---
        for NAT_ID in $(aws ec2 describe-nat-gateways \
            --filter Name=vpc-id,Values=$VPC_ID \
            --query "NatGateways[?State!='deleted'].NatGatewayId" --output text); do
            echo "   ↳ Deleting NAT Gateway $NAT_ID"
            aws ec2 delete-nat-gateway --nat-gateway-id $NAT_ID
        done

        # --- Delete Subnets ---
        for SUBNET_ID in $(aws ec2 describe-subnets \
            --filters Name=vpc-id,Values=$VPC_ID \
            --query "Subnets[].SubnetId" --output text); do
            echo "   ↳ Deleting Subnet $SUBNET_ID"
            aws ec2 delete-subnet --subnet-id $SUBNET_ID
        done

        # --- Delete non‑default Security Groups ---
        for SG_ID in $(aws ec2 describe-security-groups \
            --filters Name=vpc-id,Values=$VPC_ID \
            --query "SecurityGroups[?GroupName!='default'].GroupId" --output text); do
            echo "   ↳ Deleting Security Group $SG_ID"
            aws ec2 delete-security-group --group-id $SG_ID
        done

        # --- Finally delete the VPC ---
        echo "   ↳ Deleting VPC $VPC_ID"
        aws ec2 delete-vpc --vpc-id $VPC_ID
        echo "✅ VPC $VPC_ID deleted"
        echo ""
    done

    echo "🎉 All non‑project VPCs have been removed. Only $KEEP_VPC remains."


    igw-079288e3da29a68b2
    aws ec2 detach-internet-gateway \
        --region us-east-2 \
        --internet-gateway-id igw-079288e3da29a68b \
        --vpc-id vpc-04fffc1fc3224e337
