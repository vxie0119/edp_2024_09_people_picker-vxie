#!/bin/bash

# Run this script once to setup the initial AWS infrastructure

# Copy necessary files
cp -f ../package*.json ../scripts/
cp -rf ../server/ ../scripts/server
cp -rf ../client ../scripts/client

# Set variables
REGION="us-west-1"
NAME="edp"
CLUSTER_NAME="$NAME-cluster"
SERVICE_NAME="$NAME-service"
TASK_DEFINITION_NAME="$NAME-task"
ECR_REPO_NAME="$NAME-people-picker"
CONTAINER_NAME="$NAME-people-picker"
LOG_GROUP_NAME="/ecs/$NAME"
CONTAINER_PORT=3001
HOST_PORT=3001

# Get AWS Account ID
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

# Use Git commit hash as IMAGE_TAG
IMAGE_TAG=$(git rev-parse --short HEAD)

# Create VPC
echo "Creating VPC..."
VPC_JSON=$(aws ec2 create-vpc --cidr-block 10.0.0.0/16 \
--tag-specifications "ResourceType=vpc,Tags=[{Key=Name,Value=$NAME-vpc}]" \
--region $REGION --output json)
VPC_ID=$(echo $VPC_JSON | jq -r '.Vpc.VpcId')
echo "VPC ID: $VPC_ID"

# Enable DNS support and hostnames
aws ec2 modify-vpc-attribute --vpc-id $VPC_ID --enable-dns-support "{\"Value\":true}" --region $REGION
aws ec2 modify-vpc-attribute --vpc-id $VPC_ID --enable-dns-hostnames "{\"Value\":true}" --region $REGION

# Create Subnet
echo "Creating Subnet..."
SUBNET_JSON=$(aws ec2 create-subnet --vpc-id $VPC_ID --cidr-block 10.0.1.0/24 \
--region $REGION --output json)
SUBNET_ID_1=$(echo $SUBNET_JSON | jq -r '.Subnet.SubnetId')
echo "Subnet ID: $SUBNET_ID_1"

# Create Internet Gateway
echo "Creating Internet Gateway..."
IGW_JSON=$(aws ec2 create-internet-gateway --region $REGION --output json)
IGW_ID=$(echo $IGW_JSON | jq -r '.InternetGateway.InternetGatewayId')
echo "Internet Gateway ID: $IGW_ID"

# Attach Internet Gateway to VPC
echo "Attaching Internet Gateway to VPC..."
aws ec2 attach-internet-gateway --internet-gateway-id $IGW_ID --vpc-id $VPC_ID --region $REGION

# Create Route Table
echo "Creating Route Table..."
ROUTE_TABLE_JSON=$(aws ec2 create-route-table --vpc-id $VPC_ID \
--region $REGION --output json)
ROUTE_TABLE_ID=$(echo $ROUTE_TABLE_JSON | jq -r '.RouteTable.RouteTableId')
echo "Route Table ID: $ROUTE_TABLE_ID"

# Create Route to Internet Gateway
echo "Creating route to Internet Gateway..."
aws ec2 create-route --route-table-id $ROUTE_TABLE_ID \
--destination-cidr-block 0.0.0.0/0 --gateway-id $IGW_ID \
--region $REGION > /dev/null

# Associate Route Table with Subnet
echo "Associating Route Table with Subnet..."
aws ec2 associate-route-table --route-table-id $ROUTE_TABLE_ID \
--subnet-id $SUBNET_ID_1 --region $REGION > /dev/null

# Modify Subnet to assign public IPs
echo "Modifying Subnet to assign public IPs..."
aws ec2 modify-subnet-attribute --subnet-id $SUBNET_ID_1 \
--map-public-ip-on-launch --region $REGION

# Create Security Group
echo "Creating Security Group..."
SECURITY_GROUP_JSON=$(aws ec2 create-security-group --group-name edp-sg \
--description "EDP Security Group" --vpc-id $VPC_ID \
--region $REGION --output json)
SECURITY_GROUP_ID=$(echo $SECURITY_GROUP_JSON | jq -r '.GroupId')
echo "Security Group ID: $SECURITY_GROUP_ID"

# Authorize inbound traffic on port $HOST_PORT
echo "Authorizing inbound traffic on port $HOST_PORT..."
aws ec2 authorize-security-group-ingress --group-id $SECURITY_GROUP_ID \
--protocol tcp --port $HOST_PORT --cidr 0.0.0.0/0 --region $REGION > /dev/null

# Create ECR repository if it doesn't exist
echo "Checking if ECR repository exists..."
ECR_REPO_CHECK=$(aws ecr describe-repositories --repository-names $ECR_REPO_NAME \
--region $REGION --output text 2>/dev/null)

if [ -z "$ECR_REPO_CHECK" ]; then
    echo "Creating ECR repository..."
    aws ecr create-repository --repository-name $ECR_REPO_NAME \
    --region $REGION > /dev/null
    echo "ECR repository '$ECR_REPO_NAME' created."
else
    echo "ECR repository '$ECR_REPO_NAME' already exists."
fi

# Get ECR repository URI
ECR_URI=$(aws ecr describe-repositories --repository-names $ECR_REPO_NAME \
--region $REGION --query 'repositories[0].repositoryUri' --output text)
echo "ECR Repository URI: $ECR_URI"

# Create DynamoDB table
echo "Checking if DynamoDB table 'people' exists..."
DDB_TABLE_CHECK=$(aws dynamodb describe-table --table-name people \
--region $REGION --output text 2>/dev/null)

if [ -z "$DDB_TABLE_CHECK" ]; then
    echo "Creating DynamoDB table 'people'..."
    aws dynamodb create-table \
        --table-name people \
        --attribute-definitions \
            AttributeName=id,AttributeType=N \
        --key-schema \
            AttributeName=id,KeyType=HASH \
        --provisioned-throughput \
            ReadCapacityUnits=5,WriteCapacityUnits=5 \
        --region $REGION > /dev/null
    echo "DynamoDB table 'people' created."
else
    echo "DynamoDB table 'people' already exists."
fi

# Create IAM role for ECS task if it doesn't exist
ROLE_NAME="ecsTaskRole"
echo "Checking if IAM role '$ROLE_NAME' exists..."
ROLE_CHECK=$(aws iam get-role --role-name $ROLE_NAME --region $REGION --output text 2>/dev/null)

if [ -z "$ROLE_CHECK" ]; then
    echo "Creating IAM role '$ROLE_NAME' for ECS task..."
    
    TRUST_POLICY=$(cat <<EOF
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Principal": {
                "Service": "ecs-tasks.amazonaws.com"
            },
            "Action": "sts:AssumeRole"
        }
    ]
}
EOF
)

    aws iam create-role --role-name $ROLE_NAME \
    --assume-role-policy-document file://<(echo "$TRUST_POLICY") \
    --region $REGION > /dev/null
    echo "IAM role '$ROLE_NAME' created."
else
    echo "IAM role '$ROLE_NAME' already exists."
fi

# Create IAM policy for DynamoDB access if it doesn't exist
POLICY_NAME="ecsTaskDynamoDBPolicy"
echo "Checking if IAM policy '$POLICY_NAME' exists..."
POLICY_ARN="arn:aws:iam::$ACCOUNT_ID:policy/$POLICY_NAME"
POLICY_CHECK=$(aws iam get-policy --policy-arn $POLICY_ARN --region $REGION --output text 2>/dev/null)

if [ -z "$POLICY_CHECK" ]; then
    echo "Creating IAM policy for DynamoDB access..."
    
    DYNAMODB_POLICY=$(cat <<EOF
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": [
                "dynamodb:*"
            ],
            "Resource": "arn:aws:dynamodb:$REGION:$ACCOUNT_ID:table/people"
        }
    ]
}
EOF
)

    aws iam create-policy --policy-name $POLICY_NAME \
    --policy-document file://<(echo "$DYNAMODB_POLICY") \
    --region $REGION > /dev/null
    echo "IAM policy '$POLICY_NAME' created."
else
    echo "IAM policy '$POLICY_NAME' already exists."
fi

# Attach IAM policy to role
echo "Attaching IAM policy to role..."
aws iam attach-role-policy --role-name $ROLE_NAME \
--policy-arn $POLICY_ARN --region $REGION

# Log in to ECR
echo "Logging in to ECR..."
aws ecr get-login-password --region $REGION | \
docker login --username AWS --password-stdin $ECR_URI

# Build Docker image
echo "Building Docker image..."
docker build -t $CONTAINER_NAME:$IMAGE_TAG .

# Tag and push Docker image to ECR
echo "Tagging and pushing Docker image to ECR..."
docker tag $CONTAINER_NAME:$IMAGE_TAG $ECR_URI:$IMAGE_TAG
docker push $ECR_URI:$IMAGE_TAG

# Create ECS cluster if it doesn't exist
echo "Checking if ECS cluster '$CLUSTER_NAME' exists..."
CLUSTER_CHECK=$(aws ecs describe-clusters --clusters $CLUSTER_NAME \
--region $REGION --output text --query 'clusters[0].status' 2>/dev/null)

if [ "$CLUSTER_CHECK" != "ACTIVE" ]; then
    echo "Creating ECS cluster..."
    aws ecs create-cluster --cluster-name $CLUSTER_NAME \
    --region $REGION > /dev/null
    echo "ECS cluster '$CLUSTER_NAME' created."
else
    echo "ECS cluster '$CLUSTER_NAME' already exists."
fi

# Create CloudWatch log group if it doesn't exist
echo "Checking if CloudWatch log group '$LOG_GROUP_NAME' exists..."
LOG_GROUP_CHECK=$(aws logs describe-log-groups --log-group-name-prefix $LOG_GROUP_NAME \
--region $REGION --output text --query 'logGroups[0].logGroupName' 2>/dev/null)

if [ -z "$LOG_GROUP_CHECK" ]; then
    echo "Creating CloudWatch log group..."
    aws logs create-log-group --log-group-name $LOG_GROUP_NAME \
    --region $REGION > /dev/null
    echo "CloudWatch log group '$LOG_GROUP_NAME' created."
else
    echo "CloudWatch log group '$LOG_GROUP_NAME' already exists."
fi

# Register ECS task definition
echo "Registering ECS task definition..."
TASK_DEF_JSON=$(cat <<EOF
{
    "family": "$TASK_DEFINITION_NAME",
    "taskRoleArn": "arn:aws:iam::$ACCOUNT_ID:role/$ROLE_NAME",
    "executionRoleArn": "arn:aws:iam::$ACCOUNT_ID:role/ecsTaskExecutionRole",
    "containerDefinitions": [
        {
            "name": "$CONTAINER_NAME",
            "image": "$ECR_URI:$IMAGE_TAG",
            "cpu": 1024,
            "memory": 4096,
            "portMappings": [
                {
                    "containerPort": $CONTAINER_PORT,
                    "hostPort": $HOST_PORT,
                    "protocol": "tcp"
                }
            ],
            "essential": true,
            "healthCheck": {
                "retries": 3,
                "command": [
                    "CMD-SHELL",
                    "curl -f http://127.0.0.1:$HOST_PORT/ || exit 1"
                ],
                "timeout": 5,
                "interval": 30,
                "startPeriod": 300
            },
            "logConfiguration": {
                "logDriver": "awslogs",
                "options": {
                    "awslogs-group": "$LOG_GROUP_NAME",
                    "awslogs-region": "$REGION",
                    "awslogs-stream-prefix": "ecs"
                }
            }
        }
    ],
    "requiresCompatibilities": [
        "FARGATE"
    ],
    "cpu": "1024",
    "memory": "4096",
    "networkMode": "awsvpc",
    "runtimePlatform": {
        "cpuArchitecture": "X86_64",
        "operatingSystemFamily": "LINUX"
    }
}
EOF
)

echo "$TASK_DEF_JSON" > task_definition.json
aws ecs register-task-definition --cli-input-json file://task_definition.json \
--region $REGION > /dev/null

# Create ECS service if it doesn't exist
echo "Checking if ECS service '$SERVICE_NAME' exists..."
SERVICE_CHECK=$(aws ecs describe-services --cluster $CLUSTER_NAME \
--services $SERVICE_NAME --region $REGION \
--output text --query 'services[0].status' 2>/dev/null)

if [ "$SERVICE_CHECK" != "ACTIVE" ]; then
    echo "Creating ECS service..."
    aws ecs create-service \
        --cluster $CLUSTER_NAME \
        --service-name $SERVICE_NAME \
        --task-definition $TASK_DEFINITION_NAME \
        --desired-count 1 \
        --launch-type FARGATE \
        --network-configuration "awsvpcConfiguration={subnets=[$SUBNET_ID_1],securityGroups=[$SECURITY_GROUP_ID],assignPublicIp=ENABLED}" \
        --region $REGION > /dev/null
    echo "ECS service '$SERVICE_NAME' created."
else
    echo "ECS service '$SERVICE_NAME' already exists."
    # Update the service with the new task definition
    echo "Updating ECS service with new task definition..."
    aws ecs update-service \
        --cluster $CLUSTER_NAME \
        --service $SERVICE_NAME \
        --task-definition $TASK_DEFINITION_NAME \
        --region $REGION > /dev/null
    echo "ECS service '$SERVICE_NAME' updated."
fi

echo "ECS service and task created successfully."