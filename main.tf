# S3 Bucket for Logstash output
resource "aws_s3_bucket" "logstash_output" {
  bucket = var.s3_bucket_name
  force_destroy = true
}

# SQS Queue for S3 notifications
resource "aws_sqs_queue" "s3_notifications" {
  name                       = "${var.prefix}-s3-notifications"
  visibility_timeout_seconds = 300
  message_retention_seconds  = 86400 # 1 day
}

resource "aws_sqs_queue_policy" "s3_notifications_policy" {
  queue_url = aws_sqs_queue.s3_notifications.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "s3.amazonaws.com"
        }
        Action   = "sqs:SendMessage"
        Resource = aws_sqs_queue.s3_notifications.arn
        Condition = {
          ArnEquals = {
            "aws:SourceArn" = aws_s3_bucket.logstash_output.arn
          }
        }
      }
    ]
  })
}

# S3 Bucket Notification Configuration
resource "aws_s3_bucket_notification" "bucket_notification" {
  bucket = aws_s3_bucket.logstash_output.id

  queue {
    queue_arn     = aws_sqs_queue.s3_notifications.arn
    events        = ["s3:ObjectCreated:*"]
  }

  depends_on = [aws_sqs_queue_policy.s3_notifications_policy]
}

# IAM Role for Logstash EC2 Instance
resource "aws_iam_role" "logstash_role" {
  name = "${var.prefix}-logstash-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
      }
    ]
  })
}

# IAM Policy for Logstash to access S3
resource "aws_iam_policy" "logstash_policy" {
  name        = "${var.prefix}-logstash-policy"
  description = "Allows Logstash to access S3"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:PutObject",
          "s3:GetObject",
          "s3:ListBucket",
          "s3:GetBucketLocation"
        ]
        Resource = [
          aws_s3_bucket.logstash_output.arn,
          "${aws_s3_bucket.logstash_output.arn}/*"
        ]
      }
    ]
  })
}

# Attach policy to role
resource "aws_iam_role_policy_attachment" "logstash_policy_attachment" {
  role       = aws_iam_role.logstash_role.name
  policy_arn = aws_iam_policy.logstash_policy.arn
}

# EC2 Instance Profile
resource "aws_iam_instance_profile" "logstash_profile" {
  name = "${var.prefix}-logstash-profile"
  role = aws_iam_role.logstash_role.name
}

# Security Group for Logstash EC2 instance
resource "aws_security_group" "logstash_sg" {
  name        = "${var.prefix}-logstash-sg"
  description = "Security group for Logstash instance"
  vpc_id      = var.vpc_id

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "SSH access"
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Allow all outbound traffic"
  }
}

# EC2 Instance Key Pair
resource "aws_key_pair" "logstash_key" {
  key_name   = "${var.prefix}-logstash-key"
  public_key = file("~/.ssh/id_rsa.pub")
}

# EC2 Instance for Logstash
resource "aws_instance" "logstash" {
  ami                    = var.ec2_ami
  instance_type          = var.logstash_instance_type
  key_name               = aws_key_pair.logstash_key.key_name
  vpc_security_group_ids = [aws_security_group.logstash_sg.id]
  subnet_id              = var.subnet_id
  iam_instance_profile   = aws_iam_instance_profile.logstash_profile.name

  root_block_device {
    volume_size = 100
    volume_type = "gp3"
  }

  # Write userdata script with proper variables
  user_data = templatefile("${path.module}/user_data.sh", {
    setup_script = file("${path.module}/setup_logstash.sh"),
    download_script = file("${path.module}/download_logs.sh"),
    AWS_REGION = var.aws_region,
    S3_BUCKET = var.s3_bucket_name
  })

  tags = {
    Name = "${var.prefix}-logstash-instance"
  }
}

# IAM Role for Filebeat EC2 instance
resource "aws_iam_role" "filebeat_role" {
  name = "${var.prefix}-filebeat-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
      }
    ]
  })
}

# IAM Policy for Filebeat to access S3 and SQS
resource "aws_iam_policy" "filebeat_policy" {
  name        = "${var.prefix}-filebeat-policy"
  description = "Allows Filebeat to access S3 and SQS"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:ListBucket",
          "s3:GetBucketLocation"
        ]
        Resource = [
          aws_s3_bucket.logstash_output.arn,
          "${aws_s3_bucket.logstash_output.arn}/*"
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "sqs:ReceiveMessage",
          "sqs:ChangeMessageVisibility",
          "sqs:DeleteMessage",
          "sqs:GetQueueUrl",
          "sqs:GetQueueAttributes"
        ]
        Resource = aws_sqs_queue.s3_notifications.arn
      }
    ]
  })
}

# Attach policy to role
resource "aws_iam_role_policy_attachment" "filebeat_policy_attachment" {
  role       = aws_iam_role.filebeat_role.name
  policy_arn = aws_iam_policy.filebeat_policy.arn
}

# EC2 Instance Profile
resource "aws_iam_instance_profile" "filebeat_profile" {
  name = "${var.prefix}-filebeat-profile"
  role = aws_iam_role.filebeat_role.name
}

# Security Group for EC2 instance
resource "aws_security_group" "filebeat_sg" {
  name        = "${var.prefix}-filebeat-sg"
  description = "Security group for Filebeat instance"
  vpc_id      = var.vpc_id

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "SSH access"
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Allow all outbound traffic"
  }
}

# EC2 Instance Key Pair
resource "aws_key_pair" "filebeat_key" {
  key_name   = "${var.prefix}-filebeat-key"
  public_key = file("~/.ssh/id_rsa.pub")
}

# EC2 Instance for Filebeat
resource "aws_instance" "filebeat" {
  ami                    = var.ec2_ami
  instance_type          = var.filebeat_instance_type
  key_name               = aws_key_pair.filebeat_key.key_name
  vpc_security_group_ids = [aws_security_group.filebeat_sg.id]
  subnet_id              = var.subnet_id
  iam_instance_profile   = aws_iam_instance_profile.filebeat_profile.name

  user_data = templatefile("${path.module}/setup_filebeat.sh", {
    elastic_cloud_id = var.elastic_cloud_id
    elastic_api_key  = var.elastic_api_key
    sqs_queue_url    = aws_sqs_queue.s3_notifications.url
    aws_region       = var.aws_region
  })

  tags = {
    Name = "${var.prefix}-filebeat-instance"
  }
}