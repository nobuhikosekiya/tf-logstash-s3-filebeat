#!/usr/bin/env python3
"""
Remote Log Download and Elasticsearch Ingestion Monitor

This script:
1. Connects to a remote server via SSH
2. Checks if logs have been downloaded or downloads them if needed
3. Creates symlinks from split logs to the Logstash monitor directory
4. Monitors Elasticsearch for log ingestion
5. Continues monitoring until the log count stops increasing for a specified period

Requirements:
- Python 3.6+
- paramiko (SSH client)
- elasticsearch
- argparse

Usage:
  python3 monitor_logs_ingestion.py --server SERVER_IP --username USERNAME 
                                    --ssh-key SSH_KEY_PATH --cloud-id ELASTIC_CLOUD_ID 
                                    --api-key ELASTIC_API_KEY
                                    [--index INDEX_PATTERN] [--log-type LOG_TYPE]
                                    [--log-dir LOG_DIR] [--stable-time SECONDS]

Examples:
  # Basic usage with Linux logs
  python3 monitor_logs_ingestion.py --server 192.168.1.10 --username ubuntu --ssh-key ~/.ssh/id_rsa \\
    --cloud-id your_cloud_id --api-key your_api_key

  # Download Windows logs and monitor a specific index pattern
  python3 monitor_logs_ingestion.py --server 192.168.1.10 --username ubuntu --ssh-key ~/.ssh/id_rsa \\
    --cloud-id your_cloud_id --api-key your_api_key --log-type windows --index "filebeat-*-windows-*"

  # Download all log types and wait until count is stable for 120 seconds
  python3 monitor_logs_ingestion.py --server 192.168.1.10 --username ubuntu --ssh-key ~/.ssh/id_rsa \\
    --cloud-id your_cloud_id --api-key your_api_key --log-type all --stable-time 120
"""

import os
import sys
import time
import argparse
import paramiko
from elasticsearch import Elasticsearch
import datetime
import json

def parse_args():
    parser = argparse.ArgumentParser(description='Remote log download and Elasticsearch ingestion monitor')
    
    # SSH Connection Parameters
    ssh_group = parser.add_argument_group('SSH Connection Options')
    ssh_group.add_argument('--server', required=True, help='Remote server IP address or hostname')
    ssh_group.add_argument('--username', required=True, help='SSH username')
    ssh_group.add_argument('--ssh-key', required=True, help='Path to SSH private key')
    ssh_group.add_argument('--port', type=int, default=22, help='SSH port (default: 22)')
    
    # Download Log Options
    download_group = parser.add_argument_group('Log Download Options')
    download_group.add_argument('--log-type', default='linux', help='Log type to download (linux, windows, mac, ssh, apache, all)')
    download_group.add_argument('--log-dir', default='/opt/logstash_data', help='Directory to store logs on remote server')
    download_group.add_argument('--force-download', action='store_true', help='Force download even if logs exist')
    
    # Elasticsearch Parameters
    es_group = parser.add_argument_group('Elasticsearch Options')
    es_group.add_argument('--cloud-id', help='Elastic Cloud ID')
    es_group.add_argument('--api-key', help='Elastic API Key')
    es_group.add_argument('--credentials-file', help='Path to JSON file with cloud_id and api_key')
    es_group.add_argument('--remote-credentials', action='store_true', 
                        help='Retrieve credentials from remote server at /opt/elastic_python_credentials.json')
    es_group.add_argument('--index', default=None, help='Specific index pattern to monitor (default: filebeat-*)')

    # Monitoring Parameters
    monitor_group = parser.add_argument_group('Monitoring Options')
    monitor_group.add_argument('--stable-time', type=int, default=60, 
                              help='Time in seconds with stable document count to consider ingestion complete (default: 60)')
    monitor_group.add_argument('--check-interval', type=int, default=30, 
                              help='Interval in seconds between Elasticsearch checks (default: 30)')
    monitor_group.add_argument('--verbose', '-v', action='store_true', help='Show verbose output')

    return parser.parse_args()

def setup_ssh_client(args):
    """Create and connect SSH client"""
    try:
        client = paramiko.SSHClient()
        client.set_missing_host_key_policy(paramiko.AutoAddPolicy())
        
        print(f"Connecting to {args.server} as {args.username}...")
        client.connect(
            hostname=args.server,
            port=args.port,
            username=args.username,
            key_filename=args.ssh_key
        )
        print("SSH connection established successfully")
        return client
    except Exception as e:
        print(f"Error connecting to server: {str(e)}")
        sys.exit(1)

def execute_remote_command(ssh_client, command, verbose=False):
    """Execute command on remote server and return output"""
    if verbose:
        print(f"Executing command: {command}")
    
    stdin, stdout, stderr = ssh_client.exec_command(command)
    exit_status = stdout.channel.recv_exit_status()
    
    output = stdout.read().decode('utf-8')
    error = stderr.read().decode('utf-8')
    
    if verbose or exit_status != 0:
        if output:
            print("Command output:")
            print(output)
        if error:
            print("Command error:")
            print(error)
    
    return exit_status, output, error

def check_log_download_status(ssh_client, log_dir, verbose=False):
    """Check if logs have been downloaded already"""
    command = f"test -f {log_dir}/DOWNLOAD_COMPLETE && echo 'Downloaded' || echo 'Not Downloaded'"
    _, output, _ = execute_remote_command(ssh_client, command, verbose)
    
    if "Downloaded" in output:
        print("Log files have already been downloaded.")
        return True
    else:
        print("Log files have not been downloaded yet.")
        return False

def download_logs(ssh_client, args):
    """Execute download_logs.sh on remote server without creating symlinks"""
    print(f"Downloading {args.log_type} logs to {args.log_dir}...")
    
    # Build download command without the --link option
    download_cmd = f"sudo /opt/download_logs.sh --type {args.log_type} --dir {args.log_dir} --split 500"
    
    # Execute download command
    exit_status, output, error = execute_remote_command(ssh_client, download_cmd, args.verbose)
    
    if exit_status != 0:
        print(f"Error downloading logs: Exit status {exit_status}")
        if error:
            print(error)
        return False
    
    print("Log download completed successfully")
    return True

def create_symlinks(ssh_client, log_dir, verbose=False):
    """Create symlinks from split log files to Logstash monitor directory"""
    print("Creating symlinks for Logstash to monitor split log files...")
    
    # Command to create the monitor directory
    mkdir_cmd = f"sudo mkdir -p {log_dir}/logstash_input"
    execute_remote_command(ssh_client, mkdir_cmd, verbose)
    
    # Command to find split files and create symlinks using the basename only
    symlink_cmd = f"""
    sudo find {log_dir} -path "*/split_logs/*" -type f -not -name "*.original" | while read -r file; do
        sudo ln -sf "$file" "{log_dir}/logstash_input/$(basename "$file")"
    done
    """
    
    exit_status, output, error = execute_remote_command(ssh_client, symlink_cmd, verbose)
    
    if exit_status != 0:
        print(f"Error creating symlinks: Exit status {exit_status}")
        if error:
            print(error)
        return False
    
    # Count the symlinks created
    count_cmd = f"ls -la {log_dir}/logstash_input/ | wc -l"
    _, count_output, _ = execute_remote_command(ssh_client, count_cmd, verbose)
    
    try:
        # Subtract 3 for "total", ".", and ".." entries
        link_count = int(count_output.strip()) - 3
        if link_count < 0:
            link_count = 0
        print(f"Created {link_count} symlinks in {log_dir}/logstash_input/")
    except ValueError:
        print("Unable to determine the number of symlinks created")
    
    # Set permissions
    chmod_cmd = f"sudo chown -R logstash:logstash {log_dir}/logstash_input/"
    execute_remote_command(ssh_client, chmod_cmd, verbose)
    
    return True

def setup_elasticsearch_client(args):
    """Create and connect Elasticsearch client"""
    try:
        # Load credentials from file if specified
        if args.credentials_file:
            try:
                with open(args.credentials_file) as f:
                    creds = json.load(f)
                    args.cloud_id = creds.get('cloud_id', args.cloud_id)
                    args.api_key = creds.get('api_key', args.api_key)
            except Exception as e:
                print(f"Error reading credentials file: {e}")
        
        print(f"Connecting to Elasticsearch with Cloud ID...")
        es = Elasticsearch(
            cloud_id=args.cloud_id,
            api_key=args.api_key
        )
        
        # Verify connection
        if not es.ping():
            print("Failed to connect to Elasticsearch. Check your credentials and network connection.")
            sys.exit(1)
            
        print("Elasticsearch connection established successfully")
        return es
    except Exception as e:
        print(f"Error connecting to Elasticsearch: {str(e)}")
        sys.exit(1)

def get_default_index_pattern(args):
    """Get default index pattern based on log type"""
    today = datetime.datetime.now().strftime("%Y.%m.%d")
    return f"filebeat-*"
    if args.log_type == 'all':
        return f"filebeat-7.*-{today}"
    elif args.log_type in ['linux', 'windows', 'mac', 'ssh', 'apache']:
        return f"filebeat-7.*-{args.log_type}-{today}"
    else:
        return f"filebeat-7.*-{today}"

def get_doc_count(es, index_pattern, verbose=False):
    """Get document count for the given index pattern"""
    try:
        # Check if indices exist using the stats API which is more reliable for wildcards
        indices_stats = es.indices.stats(index=index_pattern)
        
        if not indices_stats.get('indices'):
            if verbose:
                print(f"No indices matching pattern {index_pattern} found.")
            return 0
        
        # Get total document count across all matching indices
        total_docs = 0
        for idx, stats in indices_stats.get('indices', {}).items():
            doc_count = stats['total']['docs']['count']
            total_docs += doc_count
            if verbose:
                print(f"Index {idx}: {doc_count} documents")
        
        return total_docs
            
    except Exception as e:
        print(f"Error checking Elasticsearch: {str(e)}")
        return 0

def get_latest_documents(es, index_pattern, count=5, verbose=False):
    """Get latest documents from the given index pattern"""
    try:
        results = es.search(
            index=index_pattern,
            body={
                "size": count,
                "sort": [{"@timestamp": {"order": "desc"}}]
            }
        )
        
        docs = []
        if results['hits']['hits']:
            for hit in results['hits']['hits']:
                docs.append({
                    "index": hit['_index'],
                    "timestamp": hit['_source'].get('@timestamp', 'N/A'),
                    "id": hit['_id'],
                    "fields": list(hit['_source'].keys())
                })
                
        return docs
            
    except Exception as e:
        print(f"Error fetching latest documents: {str(e)}")
        return []

def monitor_elasticsearch(es, args):
    """Monitor Elasticsearch for log ingestion"""
    print("Starting Elasticsearch monitoring...")
    
    # Determine index pattern
    index_pattern = args.index if args.index else get_default_index_pattern(args)
    print(f"Monitoring index pattern: {index_pattern}")
    
    # Get initial document count
    initial_count = get_doc_count(es, index_pattern, args.verbose)
    print(f"Initial document count: {initial_count}")
    
    # Set up monitoring variables
    stable_count = initial_count
    stable_since = time.time()
    last_count = initial_count
    max_count = initial_count
    
    # Monitor loop
    try:
        print(f"Monitoring for new documents (will stop after {args.stable_time} seconds of stable count)...")
        print("-" * 80)
        print(f"{'Timestamp':<25} | {'Doc Count':<10} | {'New Docs':<10} | {'Status':<40}")
        print("-" * 80)
        
        while True:
            current_time = time.time()
            time_now = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
            
            # Get current document count
            current_count = get_doc_count(es, index_pattern, False)
            new_docs = current_count - last_count
            last_count = current_count
            
            # Update max count
            if current_count > max_count:
                max_count = current_count
            
            # Calculate time since stable
            time_since_stable = int(current_time - stable_since)
            
            # Determine status message
            if current_count == initial_count:
                status = "Waiting for first documents..."
            elif new_docs > 0:
                status = f"Ingesting logs ({new_docs} new)"
                stable_count = current_count
                stable_since = current_time
            else:
                status = f"Stable for {time_since_stable}s"
            
            # Print status row
            print(f"{time_now:<25} | {current_count:<10} | {new_docs:+<10} | {status:<40}")
            
            # Check if we've reached stable state
            if current_count > initial_count and current_count == stable_count and (current_time - stable_since) >= args.stable_time:
                print("-" * 80)
                print(f"Document count has been stable at {current_count} for {args.stable_time} seconds")
                break
                
            # Wait before next check
            time.sleep(args.check_interval)
            
        # Show summary
        print("\nIngestion Summary:")
        print(f"Total documents: {current_count}")
        print(f"New documents: {current_count - initial_count}")
        
        # Show sample documents if verbose
        if args.verbose and current_count > 0:
            print("\nLatest documents:")
            latest_docs = get_latest_documents(es, index_pattern, 3)
            for i, doc in enumerate(latest_docs):
                print(f"\n[{i+1}] Document from index: {doc['index']}")
                print(f"    Timestamp: {doc['timestamp']}")
                print(f"    ID: {doc['id']}")
                print(f"    Available fields: {', '.join(doc['fields'][:10])}{'...' if len(doc['fields']) > 10 else ''}")
            
        return current_count - initial_count
        
    except KeyboardInterrupt:
        print("\nMonitoring interrupted by user.")
        return current_count - initial_count

def run_check_elastic_script(ssh_client, args):
    """Run check_elastic_data.py script on remote server"""
    print("Running Elasticsearch check script on the remote server...")
    
    check_cmd = f"python3 /opt/check_elastic_data.py --cloud-id {args.cloud_id} --api-key {args.api_key}"
    if args.index:
        check_cmd += f" --index {args.index}"
    if args.verbose:
        check_cmd += " --verbose"
    
    # Execute check command
    exit_status, output, error = execute_remote_command(ssh_client, check_cmd, args.verbose)
    
    if exit_status != 0:
        print(f"Warning: Elasticsearch check script returned non-zero status: {exit_status}")
    
    if output:
        print("\nElasticsearch Check Results:")
        print(output)
    
    return exit_status == 0

def main():
    args = parse_args()
    
    if args.credentials_file:
        try:
            with open(args.credentials_file) as f:
                creds = json.load(f)
                args.cloud_id = creds.get('cloud_id', args.cloud_id)
                args.api_key = creds.get('api_key', args.api_key)
        except Exception as e:
            print(f"Error reading credentials file: {e}")
    
    # Set up SSH client
    ssh_client = setup_ssh_client(args)
    
    try:
        # Check if logs have been downloaded
        logs_downloaded = check_log_download_status(ssh_client, args.log_dir, args.verbose)
        
        # Download logs if needed or if forced
        if not logs_downloaded or args.force_download:
            if not download_logs(ssh_client, args):
                print("Failed to download logs. Exiting.")
                sys.exit(1)
        
        # Create symlinks for Logstash
        if not create_symlinks(ssh_client, args.log_dir, args.verbose):
            print("Failed to create symlinks. Exiting.")
            sys.exit(1)
        
        # Restart Logstash to pick up the new files
        print("Restarting Logstash service to process new files...")
        restart_cmd = "sudo systemctl restart logstash"
        execute_remote_command(ssh_client, restart_cmd, args.verbose)
        
        # Wait a moment for Logstash to start
        print("Waiting 10 seconds for Logstash to start processing...")
        time.sleep(10)
        
        # Set up Elasticsearch client
        es = setup_elasticsearch_client(args)
        
        # Monitor Elasticsearch for log ingestion
        new_docs = monitor_elasticsearch(es, args)
        
        if new_docs > 0:
            print(f"\nSuccess: {new_docs} new documents were ingested into Elasticsearch.")
            
            # Optionally run the check_elastic_data.py script on remote server
            if args.verbose:
                try:
                    run_check_elastic_script(ssh_client, args)
                except Exception as e:
                    print(f"Error running check script: {str(e)}")
            
            sys.exit(0)
        else:
            print("\nWarning: No new documents were ingested into Elasticsearch.")
            sys.exit(1)
            
    finally:
        # Close SSH connection
        if ssh_client:
            ssh_client.close()
            print("SSH connection closed")

if __name__ == "__main__":
    main()