variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "ap-northeast-1"
}

variable "aws_profile" {
  description = "AWS profile to use"
  type        = string
  default     = "elastic-sa"
}

variable "prefix" {
  description = "Prefix for resource names"
  type        = string
  default     = "filebeat-s3"
}

variable "default_tags" {
  description = "AWS default tags for resources"
  type        = map(string)
  default     = {}
}

variable "s3_bucket_name" {
  description = "Name of the S3 bucket for log storage"
  type        = string
  default     = ""
}

variable "s3_bucket_prefix" {
  description = "Prefix path in the S3 bucket to monitor"
  type        = string
  default     = "windows_events/"
}

variable "vpc_id" {
  description = "VPC ID where EC2 instance will be launched"
  type        = string
  default     = null
}

variable "subnet_id" {
  description = "Subnet ID where EC2 instance will be launched"
  type        = string
  default     = null
}

variable "ec2_ami" {
  description = "AMI ID for EC2 instance (Ubuntu 22.04 LTS)"
  type        = string
  default     = "ami-0df0b6d6f125b17a1"  # Ubuntu 22.04 LTS in ap-northeast-1
}

variable "logstash_instance_type" {
  description = "EC2 instance type for Logstash"
  type        = string
  default     = "t3.large"
}

variable "filebeat_instance_type" {
  description = "EC2 instance type for Filebeat"
  type        = string
  default     = "t3.small"
}

variable "elastic_cloud_id" {
  description = "Elastic Cloud deployment ID"
  type        = string
  sensitive   = true
}

variable "elastic_api_key" {
  description = "Elastic Cloud API key for Filebeat"
  type        = string
  sensitive   = true
}

variable "elastic_python_api_key" {
  description = "Elastic Cloud API key for Python monitoring tools"
  type        = string
  sensitive   = true
  default     = ""  # Default to empty string, will use filebeat key if not specified
}