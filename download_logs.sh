#!/bin/bash
# Script to download sample log files with options for different log types
# Modified to include file splitting functionality for large files

# Define usage function
usage() {
  echo "Usage: $0 [OPTIONS]"
  echo "Download sample log files for testing with Logstash and Filebeat."
  echo ""
  echo "Options:"
  echo "  -t, --type TYPE    Log type to download (linux, windows, mac, ssh, apache, all)"
  echo "                     Default: linux"
  echo "  -d, --dir DIR      Directory to store logs (default: /opt/logstash_data)"
  echo "  -s, --split SIZE   Maximum size of split files in MB (default: 500)"
  echo "  -l, --link         Create symlinks in LOGSTASH_MONITOR_DIR (default: false)"
  echo "  -h, --help         Display this help message and exit"
  echo ""
  echo "Examples:"
  echo "  $0 --type windows          # Download only Windows logs"
  echo "  $0 --type all              # Download all log types"
  echo "  $0 --type linux,apache     # Download Linux and Apache logs"
  echo "  $0 --dir /custom/dir       # Download to a custom directory"
  echo "  $0 --split 250             # Split files to max 250MB chunks"
  echo "  $0 --link                  # Create symlinks after downloading"
}

# Default values
LOG_DIR="/opt/logstash_data"
LOG_TYPE="linux"
SPLIT_SIZE=500  # Default max size in MB
CREATE_LINKS=false

# Parse command line arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    -t|--type)
      LOG_TYPE="$2"
      shift 2
      ;;
    -d|--dir)
      LOG_DIR="$2"
      shift 2
      ;;
    -s|--split)
      SPLIT_SIZE="$2"
      shift 2
      ;;
    -l|--link)
      CREATE_LINKS=true
      shift
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

# Create log directory if it doesn't exist
mkdir -p "$LOG_DIR"
cd "$LOG_DIR" || { echo "Error: Failed to change to directory $LOG_DIR"; exit 1; }

# Define log sources
declare -A LOG_SOURCES=(
  ["linux"]="https://zenodo.org/records/8196385/files/Linux.tar.gz?download=1"
  ["windows"]="https://zenodo.org/records/8196385/files/Windows.tar.gz?download=1"
  ["mac"]="https://zenodo.org/records/8196385/files/Mac.tar.gz?download=1"
  ["ssh"]="https://zenodo.org/records/8196385/files/SSH.tar.gz?download=1"
  ["apache"]="https://zenodo.org/records/8196385/files/Apache.tar.gz?download=1"
)

# Function to split large log files
split_large_files() {
  local dir=$1
  local max_size_bytes=$((SPLIT_SIZE * 1024 * 1024))  # Convert MB to bytes
  
  echo "Checking for large files to split (max size: ${SPLIT_SIZE}MB)..."
  
  # Create a directory for split files
  mkdir -p "${dir}/split_logs"
  
  # Find files larger than max size
  find "$dir" -type f -not -path "*/\.*" -not -path "*/split_logs/*" -size +${SPLIT_SIZE}M | while read -r large_file; do
    echo "Found large file: $large_file ($(du -h "$large_file" | cut -f1))"
    
    # Get filename without path
    filename=$(basename "$large_file")
    base_name="${filename%.*}"
    extension="${filename##*.}"
    
    # Create subdirectory for split files for this specific file
    split_dir="${dir}/split_logs/${base_name}_splits"
    mkdir -p "$split_dir"
    
    # Split the file
    echo "Splitting $filename into ${SPLIT_SIZE}MB chunks..."
    split -b ${max_size_bytes} -d "$large_file" "${split_dir}/${base_name}_part_"
    
    # Add proper extension to split files
    for split_file in "${split_dir}/${base_name}_part_"*; do
      mv "$split_file" "${split_file}.${extension}"
    done
    
    echo "Split $filename into $(ls "${split_dir}" | wc -l) parts in ${split_dir}"
    
    # Optional: Remove or move the original large file to save space
    # Rename original file to indicate it's been split
    mv "$large_file" "${large_file}.original"
    echo "Original file renamed to ${large_file}.original"
  done
}

# Function to download and extract logs
download_logs() {
  local log_type=$1
  local url=${LOG_SOURCES[$log_type]}
  
  if [[ -z "$url" ]]; then
    echo "Error: Unknown log type '$log_type'"
    return 1
  fi
  
  # Create subdirectory for this log type
  mkdir -p "$LOG_DIR/$log_type"
  cd "$LOG_DIR/$log_type" || { echo "Error: Failed to change to directory $LOG_DIR/$log_type"; return 1; }
  
  local archive_file="${log_type}_logs.tar.gz"
  
  # Check if the directory already has content (besides the archive file)
  if find . -type f ! -name "$archive_file" | grep -q .; then
    echo "Files already exist in $LOG_DIR/$log_type, skipping download and extraction."
    cd "$LOG_DIR" || { echo "Error: Failed to change to directory $LOG_DIR"; return 1; }
    return 0
  fi
  
  # Check if archive already exists
  if [[ -f "$archive_file" ]]; then
    echo "Archive $archive_file already exists, skipping download."
  else
    echo "Downloading $log_type logs..."
    # Download the archive
    if ! wget -O "$archive_file" "$url"; then
      echo "Error: Failed to download $log_type logs"
      return 1
    fi
  fi
  
  # Extract the archive if it hasn't been extracted already
  echo "Extracting $log_type logs..."
  if ! tar -xzf "$archive_file"; then
    echo "Error: Failed to extract $log_type logs"
    return 1
  fi
  
  # Split large files after extraction
  split_large_files "$LOG_DIR/$log_type"
  
  # Keep the archive file (no longer removing it)
  echo "$log_type logs downloaded, extracted, and large files split successfully"
  cd "$LOG_DIR" || { echo "Error: Failed to change to directory $LOG_DIR"; return 1; }
  return 0
}

# Process log types
if [[ "$LOG_TYPE" == "all" ]]; then
  # Download all log types
  for log_type in "${!LOG_SOURCES[@]}"; do
    download_logs "$log_type"
  done
else
  # Split comma-separated log types and download each
  IFS=',' read -ra LOG_TYPES <<< "$LOG_TYPE"
  for log_type in "${LOG_TYPES[@]}"; do
    download_logs "$log_type"
  done
fi

# Only create symlinks if explicitly requested
if [ "$CREATE_LINKS" = true ]; then
  # Create symlinks from split files to a directory Logstash can monitor
  echo "Creating a directory for Logstash to monitor split files..."
  LOGSTASH_MONITOR_DIR="$LOG_DIR/logstash_input"
  mkdir -p "$LOGSTASH_MONITOR_DIR"

  # Find all split log files and create symlinks
  find "$LOG_DIR" -path "*/split_logs/*" -type f -not -name "*.original" | while read -r split_file; do
    ln -sf "$split_file" "$LOGSTASH_MONITOR_DIR/$(basename "$split_file")"
  done

  echo "Created symlinks for all split files in $LOGSTASH_MONITOR_DIR"
fi

# Ensure proper permissions
echo "Setting permissions..."
chown -R logstash:logstash "$LOG_DIR" 2>/dev/null || echo "Warning: Failed to set ownership (may not be an issue if not running as root)"

echo "Log download, extraction, and splitting completed successfully"
echo "Logs are available in: $LOG_DIR"

# Create a file indicating download completion
touch "$LOG_DIR/DOWNLOAD_COMPLETE"
echo "$(date)" > "$LOG_DIR/DOWNLOAD_COMPLETE"