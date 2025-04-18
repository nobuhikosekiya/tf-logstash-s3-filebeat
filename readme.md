# Logstash and Filebeat Integration for S3 Logs

This Terraform configuration creates infrastructure for processing and ingesting logs using Logstash and Filebeat with AWS S3 and SQS.

## Architecture

```
+----------------+        +---------------+        +---------------+
|                |        |               |        |               |
|  EC2 INSTANCE  |        |  AWS S3       |        |  EC2 INSTANCE |
|                |        |  BUCKET       |        |               |
|  * Logstash    | -----> |               | <----- |  * Filebeat   | -----> ELASTIC CLOUD
|  * Sample Logs |        |  * Log Store  |        |               |        (NOT CREATED
|                |        |               |        |               |         BY TERRAFORM)
+----------------+        +-------+-------+        +---------------+
                                  |
                                  | Notifications
                                  v
                          +---------------+
                          |               |
                          |  AWS SQS      |
                          |  QUEUE        |
                          |               |
                          +---------------+
```

The setup includes:

1. **Logstash EC2 Instance** (Created by Terraform):
   - Processes log data and outputs to S3
   - Downloads sample logs (Linux, Windows, Mac, SSH, Apache)
   - Sends processed logs to an S3 bucket
   - Uses IAM roles for S3 access

2. **S3 Bucket** (Created by Terraform):
   - Stores processed logs from Logstash
   - Configured with notifications for object creation events

3. **SQS Queue** (Created by Terraform):
   - Receives S3 bucket notifications when new logs are added
   - Provides a reliable queue for processing events

4. **Filebeat EC2 Instance** (Created by Terraform):
   - Monitors the SQS queue for new log file notifications
   - Retrieves logs from S3 when notified
   - Sends logs to Elastic Cloud
   - Uses IAM roles for S3 and SQS access

5. **Elastic Cloud** (NOT created by Terraform):
   - You must create this yourself before deploying this infrastructure
   - Receives and indexes the logs from Filebeat
   - Credentials are configured in the Terraform variables

## What's Configured vs. What's Not

### Configured by This Terraform Project
- AWS S3 bucket for log storage
- AWS SQS queue for notifications
- EC2 instance with Logstash installed and configured
- EC2 instance with Filebeat installed and configured
- IAM roles and policies for secure access between components
- Security groups for the EC2 instances
- Sample log download scripts
- Monitoring and validation scripts

### Not Configured (You Must Set Up)
- Elastic Cloud deployment (you need to have this ready with credentials)
- SSH key pair (must exist at `~/.ssh/id_rsa.pub`)
- VPC and subnet (you must specify IDs in variables)
- AWS credentials and profile on your local machine

## Prerequisites

- AWS CLI configured with appropriate access
- Terraform v1.0.0 or newer
- An Elastic Cloud deployment with access credentials
- SSH key pair accessible at `~/.ssh/id_rsa.pub`

## Usage

1. Create a `terraform.tfvars` file with your specific values:

```bash
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars with your specific values
```

2. Initialize Terraform:

```bash
terraform init
```

3. Review the execution plan:

```bash
terraform plan
```

4. Apply the configuration:

```bash
terraform apply
```

## Data Flow

1. Logstash on EC2:
   - Reads logs from local storage
   - Processes the logs
   - Uploads the processed logs to S3

2. S3 Bucket:
   - Stores the processed logs
   - Generates notifications on new file creation

3. SQS Queue:
   - Receives and queues S3 notifications

4. Filebeat on EC2:
   - Monitors the SQS queue
   - Retrieves and processes logs from S3
   - Forwards logs to Elastic Cloud

## Post-Installation Steps

After the infrastructure is deployed, you can:

### Option 1: Use the automated test script

The repository includes a test script that will connect to your Logstash instance and download the log files automatically:

```bash
# Make the script executable
chmod +x test_download_logs.sh

# Run the script with the Logstash instance IP
./test_download_logs.sh $(terraform output -raw logstash_instance_public_ip)

# If you're using a custom SSH key location
./test_download_logs.sh $(terraform output -raw logstash_instance_public_ip) /path/to/your/key
```

### Option 2: Manual process

If you prefer to do it manually:

1. **Download sample log files**:
   ```bash
   ssh ubuntu@<logstash_instance_public_ip>
   sudo /opt/download_logs.sh
   ```

2. **Start Logstash processing** (if not already started):
   ```bash
   sudo systemctl start logstash
   ```

## Monitoring and Troubleshooting

On the Logstash instance:
```bash
sudo /root/check_logstash.sh
```

On the Filebeat instance:
```bash
sudo /root/check_filebeat.sh
```

Several Python scripts are provided to validate the setup:
- `check_elastic_data.py` - Verifies data is reaching Elasticsearch
- `check_s3_data.py` - Verifies data is being uploaded to S3
- `monitor_logs_ingestion.py` - Comprehensive monitoring of the entire pipeline

## Security and Compliance

- IAM roles follow the least privilege principle
- All resources tagged for resource tracking
- EC2 instances use IAM roles (not access keys)
- Sensitive variables are marked as sensitive

## Resource Cleanup

When you're done with the resources:

```bash
terraform destroy
```