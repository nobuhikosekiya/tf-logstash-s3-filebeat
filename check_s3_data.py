#!/usr/bin/env python3
"""
S3 Bucket Data Check Script

This script checks if Logstash is successfully ingesting data into an S3 bucket.
It monitors the specified bucket prefix for new files and provides information about the data.

Requirements:
- Python 3.6+
- boto3 library
- AWS credentials configured (either via AWS CLI or environment variables)

Usage:
  python3 check_s3_data.py --bucket BUCKET_NAME [--prefix PREFIX] [--wait SECONDS] [--count COUNT] [--verbose]

Arguments:
  --bucket    S3 bucket name
  --prefix    Specific prefix path in the bucket (default: "linux_logs/")
  --wait      Time in seconds to wait for data to appear (polling every 10 seconds)
  --count     Number of latest files to check (default: 5)
  --verbose   Show detailed information about objects

Examples:
  # Basic check for data in the default linux_logs/ prefix
  python3 check_s3_data.py --bucket my-logstash-bucket
  
  # Check with a specific prefix and wait for new data for up to 5 minutes
  python3 check_s3_data.py --bucket my-logstash-bucket --prefix windows_events/ --wait 300

  # Check the 10 most recent files with detailed information
  python3 check_s3_data.py --bucket my-logstash-bucket --count 10 --verbose
"""

import os
import sys
import json
import time
import datetime
import argparse
import boto3
from botocore.exceptions import ClientError

def parse_args():
    parser = argparse.ArgumentParser(description='Check if data is being ingested into S3 bucket')
    parser.add_argument('--bucket', required=True, help='S3 bucket name')
    parser.add_argument('--prefix', default='linux_logs/', help='S3 bucket prefix to check')
    parser.add_argument('--wait', type=int, default=0, help='Time to wait for data in seconds')
    parser.add_argument('--count', type=int, default=5, help='Number of latest files to check')
    parser.add_argument('--verbose', '-v', action='store_true', help='Show verbose output')
    return parser.parse_args()

def get_s3_client():
    """Create and return an S3 client"""
    try:
        return boto3.client('s3')
    except Exception as e:
        print(f"Error creating S3 client: {str(e)}")
        print("Make sure your AWS credentials are configured correctly")
        sys.exit(1)

def list_s3_objects(s3_client, bucket, prefix, max_items=None):
    """List objects in S3 bucket with the given prefix"""
    try:
        paginator = s3_client.get_paginator('list_objects_v2')
        page_iterator = paginator.paginate(
            Bucket=bucket,
            Prefix=prefix
        )
        
        objects = []
        for page in page_iterator:
            if 'Contents' in page:
                objects.extend(page['Contents'])
                if max_items and len(objects) >= max_items:
                    objects = objects[:max_items]
                    break
                    
        return sorted(objects, key=lambda x: x['LastModified'], reverse=True)
    except ClientError as e:
        if e.response['Error']['Code'] == 'NoSuchBucket':
            print(f"Error: Bucket '{bucket}' does not exist")
        else:
            print(f"Error listing objects: {str(e)}")
        return []

def check_object_content(s3_client, bucket, object_key, verbose=False):
    """Check content of an S3 object and return basic stats"""
    try:
        response = s3_client.get_object(
            Bucket=bucket,
            Key=object_key
        )
        
        content_length = response['ContentLength']
        last_modified = response['LastModified']
        
        # For JSON content, try to parse and count records
        content_type = response.get('ContentType', '')
        record_count = None
        sample_data = None
        
        if 'json' in content_type.lower() or object_key.endswith('.json'):
            try:
                # Get first 100KB to check content structure without downloading entire file
                content = response['Body'].read(min(content_length, 102400)).decode('utf-8')
                
                # Try to handle various JSON formats
                if content.strip().startswith('['):
                    # JSON array
                    sample = json.loads(content)
                    if isinstance(sample, list):
                        record_count = len(sample)
                        if record_count > 0 and verbose:
                            sample_data = sample[0]
                elif content.strip().startswith('{'):
                    # Single JSON object
                    sample = json.loads(content)
                    record_count = 1
                    if verbose:
                        sample_data = sample
                else:
                    # JSON Lines format (one JSON per line)
                    lines = content.strip().split('\n')
                    record_count = len(lines)
                    if record_count > 0 and verbose:
                        sample_data = json.loads(lines[0])
                        
            except json.JSONDecodeError:
                # Not a valid JSON format or only partial content
                pass
                
        return {
            'key': object_key,
            'size': content_length,
            'last_modified': last_modified,
            'record_count': record_count,
            'sample_data': sample_data
        }
    except ClientError as e:
        print(f"Error getting object {object_key}: {str(e)}")
        return None

def format_size(size_bytes):
    """Format size in bytes to human-readable format"""
    for unit in ['B', 'KB', 'MB', 'GB']:
        if size_bytes < 1024.0:
            return f"{size_bytes:.2f} {unit}"
        size_bytes /= 1024.0
    return f"{size_bytes:.2f} TB"

def format_time_ago(timestamp):
    """Format timestamp as time ago"""
    now = datetime.datetime.now(timestamp.tzinfo)
    delta = now - timestamp
    
    if delta.days > 0:
        return f"{delta.days} day{'s' if delta.days != 1 else ''} ago"
    hours = delta.seconds // 3600
    if hours > 0:
        return f"{hours} hour{'s' if hours != 1 else ''} ago"
    minutes = (delta.seconds % 3600) // 60
    if minutes > 0:
        return f"{minutes} minute{'s' if minutes != 1 else ''} ago"
    return f"{delta.seconds % 60} second{'s' if delta.seconds % 60 != 1 else ''} ago"

def check_s3_data(bucket, prefix, max_count=5, verbose=False):
    """Check if data exists in S3 bucket and return information about recent objects"""
    s3_client = get_s3_client()
    
    print(f"Checking for data in S3 bucket: {bucket}, prefix: {prefix}")
    
    objects = list_s3_objects(s3_client, bucket, prefix, max_count)
    
    if not objects:
        print(f"No objects found in {bucket}/{prefix}")
        return False, []
    
    print(f"Found {len(objects)} objects in {bucket}/{prefix}")
    
    # Get detailed information about the most recent files
    detailed_objects = []
    for obj in objects[:max_count]:
        object_info = check_object_content(s3_client, bucket, obj['Key'], verbose)
        if object_info:
            detailed_objects.append(object_info)
    
    # Display information about the files
    for i, obj in enumerate(detailed_objects):
        print(f"\n[{i+1}] File: {obj['key']}")
        print(f"    Size: {format_size(obj['size'])}")
        print(f"    Last Modified: {obj['last_modified'].strftime('%Y-%m-%d %H:%M:%S')} ({format_time_ago(obj['last_modified'])})")
        
        if obj['record_count'] is not None:
            print(f"    Record Count: {obj['record_count']}")
        
        if verbose and obj['sample_data']:
            print("\n    Sample Data:")
            print(f"    {json.dumps(obj['sample_data'], indent=4)[:500]}...")
            if len(json.dumps(obj['sample_data'], indent=4)) > 500:
                print("    ... (truncated)")
    
    return True, detailed_objects

def main():
    args = parse_args()
    
    if args.wait > 0:
        print(f"Waiting up to {args.wait} seconds for new data...")
        start_time = time.time()
        
        # Get initial list of objects to compare against
        s3_client = get_s3_client()
        initial_objects = list_s3_objects(s3_client, args.bucket, args.prefix)
        initial_keys = set(obj['Key'] for obj in initial_objects)
        
        while time.time() - start_time < args.wait:
            current_objects = list_s3_objects(s3_client, args.bucket, args.prefix)
            current_keys = set(obj['Key'] for obj in current_objects)
            
            new_keys = current_keys - initial_keys
            
            if new_keys:
                print(f"Detected {len(new_keys)} new objects after {int(time.time() - start_time)} seconds!")
                has_data, _ = check_s3_data(args.bucket, args.prefix, args.count, args.verbose)
                if has_data:
                    return 0
                else:
                    return 1
            
            remaining = args.wait - (time.time() - start_time)
            if remaining <= 0:
                break
                
            wait_time = min(10, remaining)
            print(f"No new data detected. Waiting {wait_time:.0f} seconds before checking again...")
            time.sleep(wait_time)
        
        print(f"No new data detected after waiting {args.wait} seconds.")
        return 1
    else:
        has_data, _ = check_s3_data(args.bucket, args.prefix, args.count, args.verbose)
        return 0 if has_data else 1

if __name__ == "__main__":
    sys.exit(main())