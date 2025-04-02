#!/bin/bash
# Initialize system and prepare scripts

# Update system packages
if [ -f /etc/debian_version ]; then
  apt-get update -y
  apt-get install -y unzip wget curl
else
  yum update -y
  yum install -y unzip wget curl
fi

# Create necessary directories
mkdir -p /opt
chmod 755 /opt

# Create download script in /opt
cat > /opt/download_logs.sh << 'DOWNLOADSCRIPT'
${download_script}
DOWNLOADSCRIPT

# Write the modified setup script to file in /opt
cat > /opt/setup_logstash.sh << EOF
${setup_script}
EOF

# Replace placeholders in the setup script with actual values
sed -i 's/AWS_REGION/${AWS_REGION}/g' /opt/setup_logstash.sh
sed -i 's/S3_BUCKET/${S3_BUCKET}/g' /opt/setup_logstash.sh

# Make scripts executable
chmod +x /opt/setup_logstash.sh
chmod +x /opt/download_logs.sh

# Run the setup script
/opt/setup_logstash.sh

# Create a flag file to signal completion
echo "EC2 instance initialization complete" > /root/SETUP_COMPLETE.txt

# Download all log types with 500MB split, but don't place in LOGSTASH_MONITOR_DIR yet
# This will be done when monitor_logs_ingestion.py is run
echo "Starting log download in the background..." > /root/DOWNLOAD_STARTED.txt
nohup /opt/download_logs.sh --type all --split 500 > /root/download_logs.log 2>&1 &