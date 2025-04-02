#!/bin/bash
set -e

# Update and install dependencies
apt-get update
apt-get install -y apt-transport-https ca-certificates curl gnupg-agent software-properties-common

# Add Elastic repository
curl -fsSL https://artifacts.elastic.co/GPG-KEY-elasticsearch | apt-key add -
echo "deb https://artifacts.elastic.co/packages/7.x/apt stable main" | tee /etc/apt/sources.list.d/elastic-7.x.list

# Update and install Filebeat
apt-get update
apt-get install -y filebeat=7.*

# Configure Filebeat
cat > /etc/filebeat/filebeat.yml << EOF
filebeat.inputs:
- type: aws-s3
  queue_url: "${sqs_queue_url}"
  expand_event_list_from_field: Records
  visibility_timeout: 600
  api_timeout: 300s
  file_selectors:
    - regex: '.*'
  max_workers: 8                   # Process more files in parallel

# Configure CloudID and API key for Elastic Cloud
cloud.id: "${elastic_cloud_id}"

# Index template settings
setup.template.name: "logs-s3"
setup.template.pattern: "logs-s3-*"
setup.template.priority: 200
setup.template.settings:
  index.refresh_interval: 30s

# Enable ILM
setup.ilm.enabled: true
setup.ilm.policy_name: "filebeat"
setup.ilm.check_exists: true

# Output to Elastic Cloud
output.elasticsearch:
  # Cloud ID and Auth are automatically used when cloud.* is set
  api_key: ${elastic_api_key}
  index: "logs-s3-%%{+yyyy.MM.dd}"

  bulk_max_size: 5000
  worker: 8                        # Increase workers

# General settings
queue.mem:
  events: 8192                     # Increase in-memory queue size
  flush.min_events: 2048           # Wait for more events before flushing
  flush.timeout: 5s                # Maximum wait before flushing
  
# processors:
  # - add_host_metadata: ~
  # - add_cloud_metadata: ~

logging.level: info
logging.to_files: true
logging.files:
  path: /var/log/filebeat
  name: filebeat
  keepfiles: 7
  permissions: 0644

http.enabled: true
http.host: "localhost"
http.port: 5066
EOF

# Set AWS region in environment
echo "AWS_REGION=${aws_region}" >> /etc/environment

# Set proper permissions
chmod go-w /etc/filebeat/filebeat.yml

# Enable and start Filebeat service
systemctl enable filebeat
systemctl start filebeat

# Install AWS CLI for troubleshooting
# apt-get install -y awscli

# Create a script to check Filebeat status
cat > /root/check_filebeat.sh << 'EOF'
#!/bin/bash
systemctl status filebeat
tail -n 50 /var/log/filebeat/filebeat
EOF

chmod +x /root/check_filebeat.sh

echo "Filebeat setup completed"