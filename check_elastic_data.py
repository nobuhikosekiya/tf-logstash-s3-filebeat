#!/usr/bin/env python3
"""
Elasticsearch Data Check Script

This script checks if data exists in a specific Elasticsearch index pattern.
It can be used to verify if Filebeat is successfully sending data to Elasticsearch.

Usage:
  python3 check_elastic_data.py --cloud-id CLOUD_ID --api-key API_KEY [--index INDEX_PATTERN] [--wait SECONDS]

Arguments:
  --cloud-id   Elastic Cloud ID
  --api-key    Elastic API Key
  --index      Specific index pattern to check (default: filebeat-*-YYYY.MM.DD)
  --wait       Time in seconds to wait for data to appear (polling every 10 seconds)
"""

import os
import sys
import json
import time
import datetime
from elasticsearch import Elasticsearch
import argparse

def parse_args():
    parser = argparse.ArgumentParser(description='Check if data exists in Elasticsearch index')
    parser.add_argument('--cloud-id', required=True, help='Elastic Cloud ID')
    parser.add_argument('--api-key', required=True, help='Elastic API Key')
    parser.add_argument('--index', default=None, help='Specific index to check (default: filebeat-*)')
    parser.add_argument('--wait', type=int, default=0, help='Time to wait for data in seconds')
    parser.add_argument('--verbose', '-v', action='store_true', help='Show verbose output')
    return parser.parse_args()

def get_today_index():
    today = datetime.datetime.now().strftime("%Y.%m.%d")
    return f"filebeat-7.*-{today}"

def check_data_exists(es, index_pattern=None, verbose=False):
    if index_pattern is None:
        index_pattern = get_today_index()
    
    print(f"Checking for data in index pattern: {index_pattern}")
    
    try:
        # Check if indices exist using the stats API which is more reliable for wildcards
        indices_stats = es.indices.stats(index=index_pattern, ignore_unavailable=True)
        if not indices_stats['indices']:
            print(f"No indices matching pattern {index_pattern} found.")
            return False
        
        # Get total document count across all matching indices
        total_docs = 0
        for idx, stats in indices_stats['indices'].items():
            doc_count = stats['total']['docs']['count']
            total_docs += doc_count
            if verbose:
                print(f"Index {idx}: {doc_count} documents")
        
        if total_docs > 0:
            print(f"Found {total_docs} total documents across all indices matching {index_pattern}")
            
            # Get a sample document
            results = es.search(
                index=index_pattern,
                body={
                    "size": 1,
                    "sort": [{"@timestamp": {"order": "desc"}}]
                }
            )
            
            if results['hits']['hits']:
                sample = results['hits']['hits'][0]
                print(f"Latest document from index: {sample['_index']}")
                print(f"Document timestamp: {sample['_source'].get('@timestamp', 'N/A')}")
                
                if verbose:
                    # Print more details about the document
                    print("\nSample document fields:")
                    print(json.dumps(list(sample['_source'].keys()), indent=2))
                    
                    # Extract and print some common fields if they exist
                    interesting_fields = ['agent', 'host', 'message', 'event']
                    for field in interesting_fields:
                        if field in sample['_source']:
                            print(f"\n{field.capitalize()} information:")
                            print(json.dumps(sample['_source'][field], indent=2))
            
            return True
        else:
            print(f"Indices matching {index_pattern} exist but contain no documents.")
            return False
            
    except Exception as e:
        print(f"Error checking Elasticsearch: {str(e)}")
        return False

def main():
    args = parse_args()
    
    # Connect to Elasticsearch
    try:
        es = Elasticsearch(
            cloud_id=args.cloud_id,
            api_key=args.api_key
        )
        
        # Verify connection
        if not es.ping():
            print("Failed to connect to Elasticsearch. Check your credentials and network connection.")
            sys.exit(1)
            
    except Exception as e:
        print(f"Error connecting to Elasticsearch: {str(e)}")
        sys.exit(1)
    
    index_pattern = args.index if args.index else get_today_index()
    
    if args.wait > 0:
        print(f"Waiting up to {args.wait} seconds for data...")
        start_time = time.time()
        while time.time() - start_time < args.wait:
            if check_data_exists(es, index_pattern, args.verbose):
                print("\nSuccess: Data found in Elasticsearch!")
                sys.exit(0)
            
            remaining = args.wait - (time.time() - start_time)
            if remaining <= 0:
                break
                
            wait_time = min(10, remaining)
            print(f"No data found yet. Waiting {wait_time:.0f} seconds before retrying...")
            time.sleep(wait_time)
        
        print(f"\nError: No data found after waiting {args.wait} seconds.")
        sys.exit(1)
    else:
        if check_data_exists(es, index_pattern, args.verbose):
            print("\nSuccess: Data found in Elasticsearch!")
            sys.exit(0)
        else:
            print("\nError: No data found in Elasticsearch.")
            sys.exit(1)

if __name__ == "__main__":
    main()