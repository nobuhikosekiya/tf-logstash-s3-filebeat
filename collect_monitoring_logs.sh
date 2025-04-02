#!/bin/bash
# Script to collect monitoring information from Filebeat and Logstash instances
# Run after 'terraform apply' completes

set -e

# Default SSH key path
SSH_KEY="${SSH_KEY:-~/.ssh/id_rsa}"
# Default SSH options
SSH_OPTIONS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10"
# Default SSH user
SSH_USER="${SSH_USER:-ubuntu}"
# Output directory
LOG_DIR="monitoring_logs_$(date +%Y%m%d_%H%M%S)"

# Function to print usage
usage() {
  echo "Usage: $0 [OPTIONS]"
  echo "Collect monitoring information from Filebeat and Logstash instances"
  echo ""
  echo "Options:"
  echo "  --ssh-key PATH       Path to SSH private key (default: ~/.ssh/id_rsa)"
  echo "  --ssh-user USER      SSH username (default: ubuntu)"
  echo "  --output-dir DIR     Directory to store logs (default: ./monitoring_logs_YYYYMMDD_HHMMSS)"
  echo "  --wait SECONDS       Time to wait before collecting logs (default: 0)"
  echo "  -h, --help           Display this help message and exit"
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --ssh-key)
      SSH_KEY="$2"
      shift 2
      ;;
    --ssh-user)
      SSH_USER="$2"
      shift 2
      ;;
    --output-dir)
      LOG_DIR="$2"
      shift 2
      ;;
    --wait)
      WAIT_TIME="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1"
      usage
      exit 1
      ;;
  esac
done

# Wait if specified
if [ -n "$WAIT_TIME" ] && [ "$WAIT_TIME" -gt 0 ]; then
  echo "Waiting $WAIT_TIME seconds before collecting logs..."
  sleep "$WAIT_TIME"
fi

# Get instance IPs from terraform outputs
echo "Getting instance IPs from terraform outputs..."
FILEBEAT_IP=$(terraform output -raw filebeat_instance_public_ip 2>/dev/null)
LOGSTASH_IP=$(terraform output -raw logstash_instance_public_ip 2>/dev/null)

# Verify we have valid IPs
if [ -z "$FILEBEAT_IP" ] || [ -z "$LOGSTASH_IP" ]; then
  echo "Error: Could not get instance IPs from terraform output."
  echo "Make sure you run this script from the terraform project directory after terraform apply completes."
  exit 1
fi

echo "Filebeat IP: $FILEBEAT_IP"
echo "Logstash IP: $LOGSTASH_IP"

# Create output directory
mkdir -p "$LOG_DIR"
echo "Logs will be saved to: $LOG_DIR"

# Function to check SSH connection
check_ssh_connection() {
  local ip=$1
  local user=$2
  local key=$3
  
  echo "Testing SSH connection to $user@$ip..."
  if ssh $SSH_OPTIONS -i "$key" "$user@$ip" "echo 'SSH connection successful'" > /dev/null 2>&1; then
    echo "Connection to $user@$ip successful"
    return 0
  else
    echo "Error: Failed to connect to $user@$ip"
    return 1
  fi
}

# Function to collect logs from Filebeat instance
collect_filebeat_logs() {
  echo "Collecting Filebeat monitoring information from $FILEBEAT_IP..."
  
  # Create Filebeat logs directory
  mkdir -p "$LOG_DIR/filebeat"
  
  # Check Filebeat endpoint status
  ssh $SSH_OPTIONS -i "$SSH_KEY" "$SSH_USER@$FILEBEAT_IP" "curl -s http://localhost:5066/stats?pretty" > "$LOG_DIR/filebeat/stats.json" || echo "Failed to get Filebeat stats" > "$LOG_DIR/filebeat/stats.json.error"
  ssh $SSH_OPTIONS -i "$SSH_KEY" "$SSH_USER@$FILEBEAT_IP" "curl -s http://localhost:5066/state?pretty" > "$LOG_DIR/filebeat/state.json" || echo "Failed to get Filebeat state" > "$LOG_DIR/filebeat/state.json.error"
  ssh $SSH_OPTIONS -i "$SSH_KEY" "$SSH_USER@$FILEBEAT_IP" "curl -s http://localhost:5066/?pretty" > "$LOG_DIR/filebeat/info.json" || echo "Failed to get Filebeat info" > "$LOG_DIR/filebeat/info.json.error"
  
  # Collect additional logs
  ssh $SSH_OPTIONS -i "$SSH_KEY" "$SSH_USER@$FILEBEAT_IP" "sudo systemctl status filebeat --no-pager" > "$LOG_DIR/filebeat/service_status.txt" 2>&1 || true
  ssh $SSH_OPTIONS -i "$SSH_KEY" "$SSH_USER@$FILEBEAT_IP" "sudo tail -n 200 /var/log/filebeat/filebeat" > "$LOG_DIR/filebeat/filebeat.log" 2>&1 || true
  ssh $SSH_OPTIONS -i "$SSH_KEY" "$SSH_USER@$FILEBEAT_IP" "sudo journalctl -u filebeat -n 100 --no-pager" > "$LOG_DIR/filebeat/journalctl.log" 2>&1 || true
  
  echo "Filebeat logs collection completed"
}

# Function to collect logs from Logstash instance
collect_logstash_logs() {
  echo "Collecting Logstash monitoring information from $LOGSTASH_IP..."
  
  # Create Logstash logs directory
  mkdir -p "$LOG_DIR/logstash"
  
  # Check Logstash API endpoints
  ssh $SSH_OPTIONS -i "$SSH_KEY" "$SSH_USER@$LOGSTASH_IP" "curl -s http://localhost:9600/_node/stats?pretty" > "$LOG_DIR/logstash/node_stats.json" || echo "Failed to get Logstash node stats" > "$LOG_DIR/logstash/node_stats.json.error"
  ssh $SSH_OPTIONS -i "$SSH_KEY" "$SSH_USER@$LOGSTASH_IP" "curl -s http://localhost:9600/_node/stats/pipelines?pretty" > "$LOG_DIR/logstash/pipeline_stats.json" || echo "Failed to get Logstash pipeline stats" > "$LOG_DIR/logstash/pipeline_stats.json.error"
  ssh $SSH_OPTIONS -i "$SSH_KEY" "$SSH_USER@$LOGSTASH_IP" "curl -s http://localhost:9600/_node?pretty" > "$LOG_DIR/logstash/node_info.json" || echo "Failed to get Logstash node info" > "$LOG_DIR/logstash/node_info.json.error"
  
  # Collect additional logs
  ssh $SSH_OPTIONS -i "$SSH_KEY" "$SSH_USER@$LOGSTASH_IP" "sudo systemctl status logstash --no-pager" > "$LOG_DIR/logstash/service_status.txt" 2>&1 || true
  ssh $SSH_OPTIONS -i "$SSH_KEY" "$SSH_USER@$LOGSTASH_IP" "sudo tail -n 200 /var/log/logstash/logstash-plain.log" > "$LOG_DIR/logstash/logstash-plain.log" 2>&1 || true
  ssh $SSH_OPTIONS -i "$SSH_KEY" "$SSH_USER@$LOGSTASH_IP" "sudo ls -la /opt/logstash_data/" > "$LOG_DIR/logstash/data_directory.txt" 2>&1 || true
  ssh $SSH_OPTIONS -i "$SSH_KEY" "$SSH_USER@$LOGSTASH_IP" "sudo cat /etc/logstash/conf.d/linux_logs_to_s3.conf" > "$LOG_DIR/logstash/pipeline_config.conf" 2>&1 || true
  
  echo "Logstash logs collection completed"
}

# Main execution

# Check SSH connections
check_ssh_connection "$FILEBEAT_IP" "$SSH_USER" "$SSH_KEY" || { echo "Failed to connect to Filebeat instance"; exit 1; }
check_ssh_connection "$LOGSTASH_IP" "$SSH_USER" "$SSH_KEY" || { echo "Failed to connect to Logstash instance"; exit 1; }

# Collect logs
collect_filebeat_logs
collect_logstash_logs

# Create a summary report
cat > "$LOG_DIR/summary.txt" << EOF
=============================================
Monitoring Logs Collection Summary
=============================================
Date: $(date)
Filebeat Instance: $FILEBEAT_IP
Logstash Instance: $LOGSTASH_IP
SSH User: $SSH_USER
SSH Key: $SSH_KEY

Files collected:
----------------
$(find "$LOG_DIR" -type f | sort)
=============================================
EOF

echo "Log collection completed successfully"
echo "All logs are available in: $LOG_DIR"
echo "See $LOG_DIR/summary.txt for details"