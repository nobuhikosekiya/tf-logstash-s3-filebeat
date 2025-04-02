#!/bin/bash
# Logstash setup script optimized for Ubuntu

set -e


# Ubuntu-specific installation
echo "Detected Ubuntu system, installing dependencies..."
apt-get update
apt-get install -y openjdk-11-jdk apt-transport-https wget unzip

# Install entropy generation tools
apt-get install -y haveged

# Start and enable haveged service
systemctl start haveged
systemctl enable haveged

# Add Elastic repository and GPG key
wget -qO - https://artifacts.elastic.co/GPG-KEY-elasticsearch | apt-key add -
echo "deb https://artifacts.elastic.co/packages/7.x/apt stable main" | tee -a /etc/apt/sources.list.d/elastic-7.x.list
apt-get update
apt-get install -y logstash

# Create directories for Logstash data
mkdir -p /opt/logstash_data
chown -R logstash:logstash /opt/logstash_data

# Create Logstash configuration for Linux logs
cat > /etc/logstash/conf.d/linux_logs_to_s3.conf << EOL
input {
  file {
    path => [
      "/opt/logstash_data/logstash_input/*.log"
    ]
    start_position => "beginning"
    sincedb_path => "/var/lib/logstash/sincedb"
    codec => "plain"
    mode => "read"
    file_chunk_size => 1048576 
    # Increase the read timeout to handle large files better
    file_completed_action => "log"
    file_completed_log_path => "/var/log/logstash/completed_files.log"
  }
}

filter {
  # Add basic processing if needed
  mutate {
    add_field => { "[@metadata][process_timestamp]" => "%{@timestamp}" }
    add_field => { "file_source" => "%{[@metadata][path]}" }
  }
}

output {
  s3 {
    region => "AWS_REGION"
    bucket => "S3_BUCKET"
    prefix => "logs/"
    upload_queue_size => 8
    upload_workers_count => 8
    size_file => 10428800
    time_file => 120
    codec => json_lines
    restore => false
    rotation_strategy => "size_and_time"
    temporary_directory => "/tmp/logstash-s3"
  }
  
  # Optional: Add stdout output for debugging
  # stdout { codec => rubydebug }
}
EOL

# Install S3 output plugin with verbosity
# echo "Installing Logstash S3 output plugin (this may take a few minutes)..."
# timeout 600 /usr/share/logstash/bin/logstash-plugin install --verbose logstash-output-s3
# Configure JVM memory settings
# cat > /etc/logstash/jvm.options.d/memory.options << EOL
# -Xms1g
# -Xmx1g
# EOL

# Back up the original JVM options file
cp /etc/logstash/jvm.options /etc/logstash/jvm.options.bak

# Update memory settings in the main JVM options file
sed -i 's/-Xms1g/-Xms1g/g' /etc/logstash/jvm.options
sed -i 's/-Xmx1g/-Xmx1g/g' /etc/logstash/jvm.options

# Add entropy settings if needed
echo "-Djava.security.egd=file:/dev/urandom" >> /etc/logstash/jvm.options

# Enable and start Logstash service
systemctl enable logstash
systemctl start logstash

# Create a script to check Logstash status
cat > /root/check_logstash.sh << 'EOF'
#!/bin/bash
echo "======= Logstash Service Status ======="
systemctl status logstash
echo
echo "======= Logstash Logs ======="
tail -n 50 /var/log/logstash/logstash-plain.log
echo
echo "======= Logstash Configuration ======="
ls -la /etc/logstash/conf.d/
echo
echo "======= Logstash Pipeline Status ======="
/usr/share/logstash/bin/logstash --config.test_and_exit -f /etc/logstash/conf.d/linux_logs_to_s3.conf || echo "Configuration test failed"
EOF

chmod +x /root/check_logstash.sh

echo "Logstash setup completed successfully with AWS region: AWS_REGION and S3 bucket: S3_BUCKET"