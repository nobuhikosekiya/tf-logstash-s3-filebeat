#!/bin/bash
# Script to connect to Logstash instance and execute the download script

set -e

# Check if instance IP is provided as argument
if [ $# -lt 1 ]; then
  echo "Usage: $0 <logstash_instance_ip> [ssh_key_path]"
  echo "  - logstash_instance_ip: Public IP of the Logstash EC2 instance"
  echo "  - ssh_key_path: Optional path to SSH private key. Default: ~/.ssh/id_rsa"
  exit 1
fi

LOGSTASH_IP=$1
SSH_KEY=${2:-~/.ssh/id_rsa}
SSH_OPTIONS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"

# Try to connect as ubuntu (Ubuntu)
echo "Connecting to Ubuntu instance..."
ssh $SSH_OPTIONS -i $SSH_KEY ubuntu@$LOGSTASH_IP "echo 'Connection successful'"

# Execute the download logs script
echo "Executing download logs script on the instance..."
ssh $SSH_OPTIONS -i $SSH_KEY ubuntu@$LOGSTASH_IP "sudo /opt/download_logs.sh"

# Check Logstash status
echo "Checking Logstash status..."
ssh $SSH_OPTIONS -i $SSH_KEY ubuntu@$LOGSTASH_IP "sudo systemctl status logstash || echo 'Logstash status check failed'"
ssh $SSH_OPTIONS -i $SSH_KEY ubuntu@$LOGSTASH_IP "sudo tail -n 50 /var/log/logstash/logstash-plain.log || echo 'Failed to get Logstash logs'"

echo "Log download completed. You can now check the S3 bucket for uploaded logs."