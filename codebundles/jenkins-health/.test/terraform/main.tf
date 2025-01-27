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
  ami           = data.aws_ami.ubuntu.id
  instance_type = "t2.micro"

  subnet_id                   = aws_subnet.jenkins_subnet.id
  vpc_security_group_ids      = [aws_security_group.jenkins_sg.id]
  key_name                    = aws_key_pair.generated_key.key_name
  associate_public_ip_address = true

  user_data = <<-EOF
              #!/bin/bash
              # Update package index
              apt-get update
              # Install Java 17
              apt-get install -y openjdk-17-jdk
              # Add Jenkins repository key
              curl -fsSL https://pkg.jenkins.io/debian-stable/jenkins.io-2023.key | tee /usr/share/keyrings/jenkins-keyring.asc > /dev/null
              # Add Jenkins repository
              echo deb [signed-by=/usr/share/keyrings/jenkins-keyring.asc] https://pkg.jenkins.io/debian-stable binary/ | tee /etc/apt/sources.list.d/jenkins.list > /dev/null
              # Update package index again
              apt-get update && apt-get install -y jenkins && systemctl enable jenkins && systemctl start jenkins
              sleep 60
              # Get the initial admin password
              JENKINS_PASS=$(sudo cat /var/lib/jenkins/secrets/initialAdminPassword)

              # Install Jenkins CLI
              wget -q http://localhost:8080/jnlpJars/jenkins-cli.jar

              # Create groovy script to create admin user
              cat <<GROOVY > create_admin.groovy
              import jenkins.model.*
              import hudson.security.*
              import jenkins.install.*

              def instance = Jenkins.getInstance()

              // Skip setup wizard
              instance.setInstallState(InstallState.INITIAL_SETUP_COMPLETED)

              // Install suggested plugins
              def pm = instance.getPluginManager()
              def uc = instance.getUpdateCenter()
              uc.updateAllSites()

              def plugins = [
                  // Organization and Administration
                  "dashboard-view",
                  "cloudbees-folder",
                  "configuration-as-code",
                  "antisamy-markup-formatter",
                  
                  // Build Features
                  "build-name-setter",
                  "build-timeout",
                  "config-file-provider",
                  "credentials-binding",
                  "embeddable-build-status",
                  "rebuild",
                  "ssh-agent",
                  "throttle-concurrents",
                  "timestamper",
                  "ws-cleanup",
                  
                  // Build Tools
                  "ant",
                  "gradle",
                  
                  // Pipelines and Continuous Delivery
                  "workflow-aggregator",
                  "github-branch-source",
                  "pipeline-github-lib",
                  "pipeline-stage-view",
                  "conditional-buildstep",
                  "parameterized-trigger",
                  "copyartifact",
                  
                  // Source Code Management
                  "git",
                  "github",
                  
                  // Distributed Builds
                  "ssh-slaves",
                  
                  // User Management and Security
                  "matrix-auth",
                  "pam-auth",
                  "ldap",
                  
                  // Notifications and Publishing
                  "email-ext",
                  "mailer",

                  "configuration-as-code",
                  "ec2"
              ]

              plugins.each { plugin ->
                  if (!pm.getPlugin(plugin)) {
                      def installFuture = uc.getPlugin(plugin).deploy()
                      installFuture.get()
                  }
              }

              // Create admin user
              def hudsonRealm = new HudsonPrivateSecurityRealm(false)
              hudsonRealm.createAccount("admin", "admin123!")
              instance.setSecurityRealm(hudsonRealm)

              def strategy = new FullControlOnceLoggedInAuthorizationStrategy()
              strategy.setAllowAnonymousRead(false)
              instance.setAuthorizationStrategy(strategy)

              instance.save()
              GROOVY

              # Execute the groovy script using Jenkins CLI
              java -jar jenkins-cli.jar -s http://localhost:8080 -auth admin:$JENKINS_PASS groovy = < create_admin.groovy || {
                echo "Failed to create admin user"
                exit 1
              }

              # Clean up
              rm -f create_admin.groovy

              EOF

  tags = {
    Name = "jenkins-server"
  }
}

output "jenkins_public_ip" {
  value = aws_instance.jenkins_server.public_ip
}

output "ssh_connection_string" {
  value = "ssh -i jenkins-key.pem ubuntu@${aws_instance.jenkins_server.public_ip}"
}