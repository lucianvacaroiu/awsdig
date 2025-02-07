#!/bin/bash

# Colors for better output readability
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to check AWS CLI and credentials
check_prerequisites() {
    if ! command -v aws &> /dev/null; then
        echo -e "${RED}AWS CLI is not installed. Please install it first.${NC}"
        exit 1
    fi

    aws sts get-caller-identity &> /dev/null
    if [ $? -ne 0 ]; then
        echo -e "${RED}AWS credentials not configured. Please configure them first.${NC}"
        exit 1
    fi
}

# Get all regions
get_regions() {
    aws ec2 describe-regions --query 'Regions[].RegionName' --output table
}

# Function to scan a specific service in a region
scan_service() {
    local region=$1
    local service=$2
    local command=$3

    echo -e "${BLUE}Scanning $service in $region...${NC}"
    aws $service $command --no-paginate --no-cli-pager --region $region 2>/dev/null
}

# Main function to scan resources
scan_resources() {
    local region=$1

    echo -e "\n${GREEN}=== Scanning region: $region ===${NC}"

    # =============================================
    echo -e "\n${BLUE}=== COMPUTE SERVICES ===${NC}"
    # EC2 & Related
    scan_service $region ec2 "describe-instances --query 'Reservations[].Instances[].[InstanceId,State.Name,InstanceType]' --output table"
    scan_service $region ec2 "describe-vpcs --query 'Vpcs[].[VpcId,State,CidrBlock]' --output table"
    scan_service $region ec2 "describe-security-groups --query 'SecurityGroups[].[GroupId,GroupName]' --output table"

    # Container Services
    scan_service $region ecs "list-clusters --output table"
    scan_service $region eks "list-clusters --output table"
    scan_service $region ecr "describe-repositories --query 'repositories[].[repositoryName,repositoryUri]' --output table"

    # Serverless
    scan_service $region lambda "list-functions --query 'Functions[].[FunctionName,Runtime,MemorySize]' --output table"
    scan_service $region apprunner "list-services --query 'ServiceSummaryList[].[ServiceName,Status]' --output table"

    # Other Compute
    scan_service $region batch "describe-compute-environments --query 'computeEnvironments[].[computeEnvironmentName,state]' --output table"
    scan_service $region elasticbeanstalk "describe-applications --query 'Applications[].[ApplicationName,DateCreated]' --output table"
    scan_service $region appstream "describe-fleets --query 'Fleets[].[Name,State]' --output table"
    scan_service $region workspaces "describe-workspaces --query 'Workspaces[].[WorkspaceId,UserName]' --output table"

    # =============================================
    echo -e "\n${BLUE}=== STORAGE SERVICES ===${NC}"
    # Object Storage
    if [ "$region" = "us-east-1" ]; then
        scan_service $region s3api "list-buckets --query 'Buckets[].Name' --output table"
    fi

    # File Storage
    scan_service $region efs "describe-file-systems --query 'FileSystems[].[FileSystemId,Name]' --output table"
    scan_service $region fsx "describe-file-systems --query 'FileSystems[].[FileSystemId,FileSystemType]' --output table"
    scan_service $region storagegateway "list-gateways --query 'Gateways[].[GatewayARN,GatewayType]' --output table"

    # =============================================
    echo -e "\n${BLUE}=== DATABASE SERVICES ===${NC}"
    # Relational Databases
    scan_service $region rds "describe-db-instances --query 'DBInstances[].[DBInstanceIdentifier,Engine,DBInstanceStatus]' --output table"
    scan_service $region redshift "describe-clusters --query 'Clusters[].[ClusterIdentifier,NodeType,ClusterStatus]' --output table"

    # NoSQL Databases
    scan_service $region dynamodb "list-tables --output table"
    scan_service $region neptune "describe-db-clusters --query 'DBClusters[].[DBClusterIdentifier,Status]' --output table"
    scan_service $region docdb "describe-db-clusters --query 'DBClusters[].[DBClusterIdentifier,Status]' --output table"
    scan_service $region memorydb "list-clusters --query 'Clusters[].[Name,Status]' --output table"

    # Caching
    scan_service $region elasticache "describe-cache-clusters --query 'CacheClusters[].[CacheClusterId,Engine,CacheClusterStatus]' --output table"

    # =============================================
    echo -e "\n${BLUE}=== MESSAGING & INTEGRATION SERVICES ===${NC}"
    # Messaging
    scan_service $region sqs "list-queues --output table"
    scan_service $region sns "list-topics --output table"
    scan_service $region kafka "list-clusters --query 'ClusterInfoList[].[ClusterName,ClusterArn]' --output table"
    scan_service $region kinesis "list-streams --output table"

    # Integration
    scan_service $region eventbridge "list-rules --query 'Rules[].[Name,State]' --output table"
    scan_service $region stepfunctions "list-state-machines --query 'stateMachines[].[name,stateMachineArn]' --output table"
    scan_service $region mwaa "list-environments --query 'Environments[]' --output table"

    # =============================================
    echo -e "\n${BLUE}=== API & DEVELOPMENT SERVICES ===${NC}"
    # API Services
    scan_service $region apigateway "get-rest-apis --query 'items[].[id,name]' --output table"
    scan_service $region appsync "list-graphql-apis --query 'graphqlApis[].[name,apiId]' --output table"

    # Development Tools
    scan_service $region codebuild "list-projects --output table"
    scan_service $region codepipeline "list-pipelines --query 'pipelines[].[name]' --output table"
    scan_service $region codeartifact "list-domains --query 'domains[].[name,owner]' --output table"
    scan_service $region amplify "list-apps --query 'apps[].[name,appId]' --output table"

    # =============================================
    echo -e "\n${BLUE}=== ANALYTICS & ML SERVICES ===${NC}"
    # Analytics
    scan_service $region emr "list-clusters --query 'Clusters[].[Id,Name,Status.State]' --output table"
    scan_service $region glue "list-jobs --query 'JobNames[]' --output table"
    scan_service $region timestream-write "list-databases --query 'Databases[].[DatabaseName]' --output table"

    # Machine Learning
    scan_service $region sagemaker "list-notebook-instances --query 'NotebookInstances[].[NotebookInstanceName,Status]' --output table"

    # =============================================
    echo -e "\n${BLUE}=== SECURITY & MONITORING SERVICES ===${NC}"
    # Security
    scan_service $region kms "list-keys --query 'Keys[].[KeyId,KeyArn]' --output table"
    scan_service $region secretsmanager "list-secrets --query 'SecretList[].[Name,ARN]' --output table"
    scan_service $region wafv2 "list-web-acls --scope REGIONAL --query 'WebACLs[].[Name,Id]' --output table"
    scan_service $region cognito-idp "list-user-pools --query 'UserPools[].[Id,Name]' --output table"

    # Monitoring
    scan_service $region logs "describe-log-groups --query 'logGroups[].[logGroupName]' --output table"
    scan_service $region backup "list-backup-vaults --query 'BackupVaultList[].[BackupVaultName,CreationDate]' --output table"
    scan_service $region grafana "list-workspaces --query 'workspaces[].[name,status]' --output table"
    scan_service $region amp "list-workspaces --query 'workspaces[].[workspaceId,status]' --output table"

    # =============================================
    echo -e "\n${BLUE}=== MEDIA SERVICES ===${NC}"
    scan_service $region mediaconvert "list-queues --query 'Queues[].[Name,Status]' --output table"
    scan_service $region medialive "list-channels --query 'Channels[].[Id,Name]' --output table"
    scan_service $region mediapackage "list-channels --query 'Channels[].[Id,Arn]' --output table"
    scan_service $region elastictranscoder "list-pipelines --query 'Pipelines[].[Id,Name]' --output table"

    # =============================================
    echo -e "\n${BLUE}=== SPECIALIZED SERVICES ===${NC}"
    # IoT
    scan_service $region iot "list-things --query 'things[].[thingName,thingTypeName]' --output table"

    # Game Development
    scan_service $region gamelift "list-fleets --query 'FleetIds[]' --output table"

    # Location Services
    scan_service $region location "list-maps --query 'Entries[].[MapName]' --output table"

    # Migration & Transfer
    scan_service $region datasync "list-tasks --query 'Tasks[]' --output table"
    scan_service $region transfer "list-servers --query 'Servers[].[ServerId,State]' --output table"

    # Blockchain
    scan_service $region managedblockchain "list-networks --query 'Networks[].[Id,Name]' --output table"
    scan_service $region qldb "list-ledgers --query 'Ledgers[]' --output table"

    # =============================================
    echo -e "\n${BLUE}=== GLOBAL SERVICES (Region-Specific Components) ===${NC}"
    # Global Accelerator (only in us-west-2)
    if [ "$region" = "us-west-2" ]; then
        scan_service $region globalaccelerator "list-accelerators --query 'Accelerators[].[Name,Status]' --output table"
    fi

    # Service Management
    scan_service $region servicequotas "list-services --query 'Services[].[ServiceCode,ServiceName]' --output table"
    scan_service $region servicecatalog "list-portfolios --query 'PortfolioDetails[].[Id,DisplayName]' --output table"

    # Legacy Services
    scan_service $region es "list-domain-names --query 'DomainNames[].[DomainName]' --output table"
}

main() {
    check_prerequisites

    echo -e "${GREEN}Starting AWS resource discovery...${NC}"

    # Get regions and filter for EU and US only
    all_regions=$(get_regions)
    echo "All available regions: $all_regions"

    regions=$(echo "$all_regions" | tr -s '[:space:]' '\n' | grep -E '^(eu|us)')
    echo "Filtered regions (US): $regions"

    # Get all regions and scan each one
    for region in $regions; do
        scan_resources $region
    done

    echo -e "\n${GREEN}Resource discovery completed!${NC}"
}

# Run the script
main
