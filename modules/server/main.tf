terraform {
  backend "s3" {
    region = "us-east-2"
    bucket = "codebrain-terraform"
    key    = "server/terraform.tfstate"
  }
  
  required_providers {
    aws = ">= 2.14.0"
  }
}

provider "aws" {
  region  = "${var.aws_region}"
  profile = "${var.aws_profile}"
}

data "aws_vpcs" "main" {
  tags = {
    Env = "${var.environment}"
  }
}

data "aws_subnet_ids" "subnets" {
  vpc_id = "${tolist(data.aws_vpcs.main.ids)[0]}"

  tags = {
    Name = "CI"
    Env = "${var.environment}"
  }
}

data "aws_ami" "ubuntu" {
  most_recent = true

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-bionic-18.04-amd64-server-*"]
  }

  owners = ["${var.canonical_account_id}"]
}

data "aws_security_groups" "groups" {
  filter {
    name   = "group-name"
    values = ["ssh", "jenkins", "sonarqube"]
  }

  filter {
    name   = "vpc-id"
    values = ["${tolist(data.aws_vpcs.main.ids)[0]}"]
  }
}

resource "random_shuffle" "subnet_id" {
  result_count = 1

  input = "${tolist(data.aws_subnet_ids.subnets.ids)}"
}

resource "aws_key_pair" "ssh_ci_key" {
  key_name   = "${var.ssh_key_name}"
  public_key = "${var.ssh_pub_key}"
}

resource "aws_launch_template" "template" {
  name_prefix   = "ci_server"
  key_name      = "${var.ssh_key_name}"
  instance_type = "${var.instance_type}"
  image_id      = "${data.aws_ami.ubuntu.id}"

  network_interfaces {
    delete_on_termination       = true
    associate_public_ip_address = true
    subnet_id                   = "${random_shuffle.subnet_id.result[0]}"
    security_groups             = "${tolist(data.aws_security_groups.groups.ids)}"
  }

  user_data = "${filebase64("${path.module}/templates/user_data")}"

  tag_specifications {
    resource_type = "instance"

    tags = {
      Name = "ci"
      Env  = "${var.environment}"
    }
  }
}

resource "aws_autoscaling_group" "ci" {
  name     = "ci"
  max_size = 1
  min_size = 1

  force_delete = true

  vpc_zone_identifier = "${tolist(data.aws_subnet_ids.subnets.ids)}"

  health_check_type = "EC2"
  health_check_grace_period = 300

  termination_policies = ["OldestInstance"]

  launch_template {
    id      = "${aws_launch_template.template.id}"
    version = "$Latest"
  }
}