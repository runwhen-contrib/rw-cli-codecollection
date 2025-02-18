resource "random_password" "jenkins_admin_password" {
  length      = 12
  special     = false
  min_upper   = 1
  min_lower   = 1
  min_numeric = 1
}

# Get latest Ubuntu AMI
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# Generate SSH key
resource "tls_private_key" "jenkins_key" {
  algorithm = "RSA"
  rsa_bits  = 2048
}

resource "aws_key_pair" "generated_key" {
  key_name   = "jenkins-key"
  public_key = tls_private_key.jenkins_key.public_key_openssh
}

# Save private key locally
resource "local_file" "private_key" {
  content  = tls_private_key.jenkins_key.private_key_pem
  filename = "jenkins-key.pem"

  provisioner "local-exec" {
    command = "chmod 400 jenkins-key.pem"
  }
}

# VPC Configuration
resource "aws_vpc" "jenkins_vpc" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name = "jenkins-vpc"
  }
}

# Internet Gateway
resource "aws_internet_gateway" "jenkins_igw" {
  vpc_id = aws_vpc.jenkins_vpc.id

  tags = {
    Name = "jenkins-igw"
  }
}

# Public Subnet
resource "aws_subnet" "jenkins_subnet" {
  vpc_id                  = aws_vpc.jenkins_vpc.id
  cidr_block              = "10.0.1.0/24"
  map_public_ip_on_launch = true
  availability_zone       = "us-west-2a"

  tags = {
    Name = "jenkins-subnet"
  }
}

# Route Table
resource "aws_route_table" "jenkins_rt" {
  vpc_id = aws_vpc.jenkins_vpc.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.jenkins_igw.id
  }

  tags = {
    Name = "jenkins-rt"
  }
}

# Route Table Association
resource "aws_route_table_association" "jenkins_rta" {
  subnet_id      = aws_subnet.jenkins_subnet.id
  route_table_id = aws_route_table.jenkins_rt.id
}

# Security Group
resource "aws_security_group" "jenkins_sg" {
  name        = "jenkins-sg"
  description = "Security group for Jenkins server"
  vpc_id      = aws_vpc.jenkins_vpc.id

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 8080
    to_port     = 8080
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# EC2 Instance
resource "aws_instance" "jenkins_server" {
  ami                         = data.aws_ami.ubuntu.id
  instance_type               = "t2.micro"
  subnet_id                   = aws_subnet.jenkins_subnet.id
  vpc_security_group_ids      = [aws_security_group.jenkins_sg.id]
  key_name                    = aws_key_pair.generated_key.key_name
  associate_public_ip_address = true

  user_data = <<-EOF
              #!/bin/bash
              apt-get update
              apt-get install -y openjdk-17-jdk
              curl -fsSL https://pkg.jenkins.io/debian-stable/jenkins.io-2023.key | tee /usr/share/keyrings/jenkins-keyring.asc > /dev/null
              echo deb [signed-by=/usr/share/keyrings/jenkins-keyring.asc] https://pkg.jenkins.io/debian-stable binary/ | tee /etc/apt/sources.list.d/jenkins.list > /dev/null
              apt-get update && apt-get install -y jenkins && systemctl enable jenkins && systemctl start jenkins

              # Wait a bit for Jenkins to start
              sleep 60

              # Retrieve the initial admin password (only valid until we run our Groovy script)
              JENKINS_PASS=$(sudo cat /var/lib/jenkins/secrets/initialAdminPassword)

              # Download Jenkins CLI
              wget -q http://localhost:8080/jnlpJars/jenkins-cli.jar

              # Install the Job DSL plugin
              echo "[INFO] Installing Job DSL plugin..."
              java -jar jenkins-cli.jar \
                -s http://localhost:8080 \
                -auth "admin:$JENKINS_PASS" \
                install-plugin job-dsl -deploy

              echo "[INFO] Installing Pipeline plugin (workflow-aggregator)..."
              java -jar jenkins-cli.jar \
                -s "http://localhost:8080" \
                -auth "admin:$JENKINS_PASS" \
                install-plugin workflow-aggregator -deploy

              echo "[INFO] Restarting Jenkins..."
              java -jar jenkins-cli.jar \
                -s http://localhost:8080 \
                -auth "admin:$JENKINS_PASS" \
                safe-restart

              sleep 30

              # Create Groovy script to set Jenkins to "INITIAL_SETUP_COMPLETED"
              # and create a new admin user with the random password
              cat <<GROOVY > create_admin.groovy
              import jenkins.model.*
              import hudson.security.*
              import jenkins.install.*

              def instance = Jenkins.getInstance()

              // Skip the Jenkins setup wizard
              instance.setInstallState(InstallState.INITIAL_SETUP_COMPLETED)

              // Disable CSRF
              instance.setCrumbIssuer(null)

              // Create admin user with a random password
              def hudsonRealm = new HudsonPrivateSecurityRealm(false)
              hudsonRealm.createAccount("admin", "${random_password.jenkins_admin_password.result}")
              instance.setSecurityRealm(hudsonRealm)

              def strategy = new FullControlOnceLoggedInAuthorizationStrategy()
              strategy.setAllowAnonymousRead(false)
              instance.setAuthorizationStrategy(strategy)

              instance.save()
              GROOVY

              # Use the initial Jenkins password to run the Groovy script
              java -jar jenkins-cli.jar \
                -s http://localhost:8080 \
                -auth admin:$JENKINS_PASS \
                groovy = < create_admin.groovy || {
                  echo "Failed to create admin user"
                  exit 1
                }

              rm -f create_admin.groovy

              # (Optional) Additional setup commands, e.g. Docker, etc.
              # ...
              EOF

  tags = {
    Name      = "jenkins-server",
    lifecycle = "deleteme"
  }
}


# # Instance Profile for Jenkins
# resource "aws_iam_instance_profile" "jenkins_profile" {
#   name = "jenkins_profile"
#   role = aws_iam_role.jenkins_role.name
# }

# # Security Group for Jenkins Agents
# resource "aws_security_group" "jenkins_agent_sg" {
#   name        = "jenkins-agent-sg"
#   description = "Security group for Jenkins agents"
#   vpc_id      = aws_vpc.jenkins_vpc.id

#   ingress {
#     from_port       = 22
#     to_port         = 22
#     protocol        = "tcp"
#     security_groups = [aws_security_group.jenkins_sg.id]
#   }

#   egress {
#     from_port   = 0
#     to_port     = 0
#     protocol    = "-1"
#     cidr_blocks = ["0.0.0.0/0"]
#   }

#   tags = {
#     Name = "jenkins-agent-sg"
#   }
# }



data "external" "jenkins_token" {
  depends_on = [aws_instance.jenkins_server]
  program    = ["bash", "./create_jenkins_token.sh"]

  # These JSON values get passed on stdin to the script
  query = {
    jenkins_url = "http://${aws_instance.jenkins_server.public_ip}:8080"
    username    = "admin"
    password    = "${random_password.jenkins_admin_password.result}"
  }
}

resource "null_resource" "create_jobs" {
  depends_on = [data.external.jenkins_token]

  provisioner "local-exec" {
    command = <<-EOT
      #!/usr/bin/env bash

      TOKEN='${data.external.jenkins_token.result["token"]}'
      JENKINS_URL="http://${aws_instance.jenkins_server.public_ip}:8080"

      # Define a function to check if a job exists. If yes, update; if not, create.
      function upsert_job() {
        local job_name="$1"
        local config_file="$2"

        # Check if job exists by hitting its /api/json
        local status_code
        status_code=$(curl -s -o /dev/null -w '%%{http_code}' -u "admin:$TOKEN" "$JENKINS_URL/job/$job_name/api/json")

        if [ "$status_code" = "200" ]; then
          echo "Updating job: $job_name"
          curl -X POST -u "admin:$TOKEN" \
               -H "Content-Type: application/xml" \
               --data-binary @"$config_file" \
               "$JENKINS_URL/job/$job_name/config.xml"
        else
          echo "Creating job: $job_name"
          curl -X POST -u "admin:$TOKEN" \
               -H "Content-Type: application/xml" \
               --data-binary @"$config_file" \
               "$JENKINS_URL/createItem?name=$job_name"
        fi
      }

      # Upsert each job
      upsert_job "the-fastest-job" "long-running-job.xml"
      upsert_job "this-never-breaks" "failed-job.xml"
      upsert_job "my-fun-pipeline" "failed-pipeline.xml"

      # Now queue the slow jobs (build them) -- same as before
      curl -X POST -u "admin:$TOKEN" "$JENKINS_URL/job/the-fastest-job/build"
      curl -X POST -u "admin:$TOKEN" "$JENKINS_URL/job/the-fastest-job/build"
      curl -X POST -u "admin:$TOKEN" "$JENKINS_URL/job/the-fastest-job/build"

      curl -X POST -u "admin:$TOKEN" "$JENKINS_URL/job/this-never-breaks/build"
      curl -X POST -u "admin:$TOKEN" "$JENKINS_URL/job/my-fun-pipeline/build"
    EOT
    # This ensures /bin/bash is used:
    interpreter = ["/bin/bash", "-c"]
  }
}



# Configure Jenkins EC2 agents
# resource "null_resource" "configure_jenkins_agents" {
#   depends_on = [null_resource.wait_for_jenkins]

#   connection {
#     type        = "ssh"
#     user        = "ubuntu"
#     private_key = tls_private_key.jenkins_key.private_key_pem
#     host        = aws_instance.jenkins_server.public_ip
#   }

#   provisioner "file" {
#     content     = tls_private_key.jenkins_key.private_key_pem
#     destination = "/tmp/jenkins-key.pem"
#   }

#   provisioner "file" {
#     content     = templatefile("${path.module}/configure_ec2_agent.groovy.tpl", {
#       ami_id           = data.aws_ami.ubuntu.id
#       subnet_id        = aws_subnet.jenkins_subnet.id
#       security_group_id = aws_security_group.jenkins_sg.id
#     })
#     destination = "/tmp/configure_ec2_agent.groovy"
#   }


#   provisioner "remote-exec" {
#     inline = [
#       # Setup SSH key for Jenkins
#       "sudo mkdir -p /var/lib/jenkins/.ssh",
#       "sudo mv /tmp/jenkins-key.pem /var/lib/jenkins/.ssh/",
#       "sudo chown -R jenkins:jenkins /var/lib/jenkins/.ssh",
#       "sudo chmod 700 /var/lib/jenkins/.ssh",
#       "sudo chmod 600 /var/lib/jenkins/.ssh/jenkins-key.pem",
#       "cat /tmp/configure_ec2_agent.groovy",
#       "wget -q http://localhost:8080/jnlpJars/jenkins-cli.jar",
#       # Execute the Groovy script using Jenkins CLI
#       "java -jar jenkins-cli.jar -s http://localhost:8080 -auth admin:admin123! groovy = < /tmp/configure_ec2_agent.groovy",

#       # Cleanup
#       "rm /tmp/configure_ec2_agent.groovy"
#     ]
#   }
# }

# Create IAM user for Jenkins
resource "aws_iam_user" "jenkins_user" {
  name = "jenkins-user"
}

# Create access key for the IAM user
resource "aws_iam_access_key" "jenkins_user_key" {
  user = aws_iam_user.jenkins_user.name
}

# Attach policy to the user
resource "aws_iam_user_policy_attachment" "jenkins_user_policy" {
  user       = aws_iam_user.jenkins_user.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2FullAccess"
}

# Output the credentials
output "jenkins_user_access_key" {
  value     = aws_iam_access_key.jenkins_user_key.id
  sensitive = true
}

output "jenkins_user_secret_key" {
  value     = aws_iam_access_key.jenkins_user_key.secret
  sensitive = true
}

output "jenkins_public_ip" {
  value = aws_instance.jenkins_server.public_ip
}

output "ssh_connection_string" {
  value = "ssh -i jenkins-key.pem ubuntu@${aws_instance.jenkins_server.public_ip}"
}

output "jenkins_admin_password" {
  value     = random_password.jenkins_admin_password.result
  sensitive = true
}

output "fetch_admin_passwrd" {
  value = "JENKINS_PASSWORD=$(cd terraform && terraform show -json | jq -r '.values.outputs.jenkins_admin_password.value')"
}

output "jenkins_url" {
  value = "http://${aws_instance.jenkins_server.public_ip}:8080"
}

output "jenkins_api_token" {
  value     = data.external.jenkins_token.result["token"]
  sensitive = true
}

output "fetch_jenkins_api_token" {
  value = "JENKINS_TOKEN=$(cd terraform && terraform show -json | jq -r '.values.outputs.jenkins_api_token.value')"
}

