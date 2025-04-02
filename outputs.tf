output "s3_bucket_name" {
  description = "Name of the S3 bucket for log storage"
  value       = aws_s3_bucket.logstash_output.bucket
}

output "sqs_queue_url" {
  description = "URL of the SQS queue"
  value       = aws_sqs_queue.s3_notifications.url
}

output "sqs_queue_arn" {
  description = "ARN of the SQS queue"
  value       = aws_sqs_queue.s3_notifications.arn
}

output "logstash_instance_id" {
  description = "ID of the EC2 instance running Logstash"
  value       = aws_instance.logstash.id
}

output "logstash_instance_public_ip" {
  description = "Public IP address of the Logstash EC2 instance"
  value       = aws_instance.logstash.public_ip
  # This ensures the output can be used directly in command substitution
  sensitive   = false
}

output "logstash_instance_private_ip" {
  description = "Private IP address of the Logstash EC2 instance"
  value       = aws_instance.logstash.private_ip
}

output "filebeat_instance_id" {
  description = "ID of the EC2 instance running Filebeat"
  value       = aws_instance.filebeat.id
}

output "filebeat_instance_public_ip" {
  description = "Public IP address of the Filebeat EC2 instance"
  value       = aws_instance.filebeat.public_ip
}

output "filebeat_instance_private_ip" {
  description = "Private IP address of the Filebeat EC2 instance"
  value       = aws_instance.filebeat.private_ip
}

output "logstash_commands" {
  description = "Commands to run after deployment to manage Logstash"
  value = <<-EOT
    # SSH to Logstash instance
    ssh ubuntu@${aws_instance.logstash.public_ip}

    # Download sample logs
    sudo /opt/download_logs.sh

    # Check Logstash status
    sudo systemctl status logstash

    # View Logstash logs
    sudo tail -f /var/log/logstash/logstash-plain.log

    # Restart Logstash if needed
    sudo systemctl restart logstash
  EOT
}

output "filebeat_commands" {
  description = "Commands to run after deployment to manage Filebeat"
  value = <<-EOT
    # SSH to Filebeat instance
    ssh ubuntu@${aws_instance.filebeat.public_ip}

    # Check Filebeat status
    sudo systemctl status filebeat

    # View Filebeat logs
    sudo tail -f /var/log/filebeat/filebeat

    # Restart Filebeat if needed
    sudo systemctl restart filebeat
  EOT
}

output "elasticsearch_check_local_command" {
  description = "Command to check Elasticsearch data from your local machine"
  value = <<-EOT
    # To check Elasticsearch data from your local PC:
    
    # 1. Install Python and required libraries locally:
    pip install elasticsearch requests

    # 2. Download the check script:
    scp ubuntu@${aws_instance.filebeat.public_ip}:/opt/check_elastic_data.py ./check_elastic_data.py
    chmod +x ./check_elastic_data.py
    
    # 3. Get the Cloud ID and API Key from the Filebeat instance:
    CLOUD_ID=$(ssh ubuntu@${aws_instance.filebeat.public_ip} "sudo grep 'cloud.id:' /etc/filebeat/filebeat.yml | awk '{print \$2}' | tr -d '\"'")
    API_KEY=$(ssh ubuntu@${aws_instance.filebeat.public_ip} "sudo grep 'api_key:' /etc/filebeat/filebeat.yml | awk '{print \$2}' | tr -d '\"'")
    
    # 4. Run the script locally (replace placeholders with actual values):
    ./check_elastic_data.py --cloud-id "$CLOUD_ID" --api-key "$API_KEY" --index "filebeat-*" --verbose
  EOT
}

output "s3_data_check_local_command" {
  description = "Command to check S3 data ingestion from your local machine"
  value = <<-EOT
    # To check S3 data ingestion from your local PC:
    
    # 1. Install Python and required libraries locally:
    pip install boto3
    
    # 2. Save this script to your local machine as check_s3_data.py and make it executable:
    # chmod +x check_s3_data.py
    
    # 3. Configure AWS credentials (if not already set up):
    aws configure
    # Follow prompts to enter AWS access key, secret key, region (${var.aws_region}), and output format
    
    # 4. Run the script to check if data is being ingested:
    ./check_s3_data.py --bucket ${aws_s3_bucket.logstash_output.bucket} --prefix linux_logs/
    
    # 5. To wait for new data to appear (e.g., for 5 minutes):
    ./check_s3_data.py --bucket ${aws_s3_bucket.logstash_output.bucket} --prefix linux_logs/ --wait 300
    
    # 6. To see detailed information including sample data:
    ./check_s3_data.py --bucket ${aws_s3_bucket.logstash_output.bucket} --prefix linux_logs/ --verbose
    
    # 7. To check the 10 most recent files:
    ./check_s3_data.py --bucket ${aws_s3_bucket.logstash_output.bucket} --prefix linux_logs/ --count 10
  EOT
}


output "credentials_file_creator" {
  description = "Command to create a credentials file without exposing secrets in command history"
  sensitive = true  # This ensures the output isn't shown in the terminal by default
  value = <<-EOT
    # Create a secure credentials file:
    cat > credentials.json << 'EOF'
    {
      "cloud_id": "${var.elastic_cloud_id}",
      "api_key": "${var.elastic_python_api_key == "" ? var.elastic_api_key : var.elastic_python_api_key}"
    }
    EOF
    chmod 600 credentials.json
    
    # The credentials file is now created at ./credentials.json
  EOT
}

output "monitor_logs_ingestion_command" {
  description = "Command to monitor log download and Elasticsearch ingestion from your local machine"
  value = <<-EOT
    # To monitor logs ingestion securely:
    
    # 1. First, create a credentials file (run this command separately):
    terraform output -raw credentials_file_creator > create_creds.sh && bash create_creds.sh && rm create_creds.sh
    
    # 2. Install Python and required libraries:
    pip install -r requirements.txt
    
    # 3. Download the monitoring script and check_elastic script:
    scp ubuntu@${aws_instance.filebeat.public_ip}:/opt/check_elastic_data.py ./check_elastic_data.py
    
    # 4. Update both scripts to support reading from credentials file by adding these lines:
    # In parse_args():
    #   parser.add_argument('--credentials-file', help='Path to JSON file with cloud_id and api_key')
    # 
    # Then after parsing args:
    #   if args.credentials_file:
    #       try:
    #           with open(args.credentials_file) as f:
    #               creds = json.load(f)
    #               args.cloud_id = creds.get('cloud_id', args.cloud_id)
    #               args.api_key = creds.get('api_key', args.api_key)
    #       except Exception as e:
    #           print(f"Error reading credentials file: {e}")
    
    # 5. Run the monitor script with any of these commands:
    
    # Basic usage with Linux logs:
    python3 monitor_logs_ingestion.py --server ${aws_instance.logstash.public_ip} --username ubuntu --ssh-key ~/.ssh/id_rsa --credentials-file credentials.json
    
    # Download Windows logs:
    python3 monitor_logs_ingestion.py --server ${aws_instance.logstash.public_ip} --username ubuntu --ssh-key ~/.ssh/id_rsa --credentials-file credentials.json --log-type windows
    
    # Download all log types and wait until count is stable for 120 seconds:
    python3 monitor_logs_ingestion.py --server ${aws_instance.logstash.public_ip} --username ubuntu --ssh-key ~/.ssh/id_rsa --credentials-file credentials.json --log-type all --stable-time 120
    
    # Show verbose output:
    python3 monitor_logs_ingestion.py --server ${aws_instance.logstash.public_ip} --username ubuntu --ssh-key ~/.ssh/id_rsa --credentials-file credentials.json --verbose
  EOT
}