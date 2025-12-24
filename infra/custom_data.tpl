#!/bin/bash

sleep 30

sudo apt-get update -y
sudo apt-get install -y ca-certificates curl gnupg lsb-release git

# 安装docker
curl -fsSL https://get.docker.com | sudo sh
sudo usermod -aG docker azureuser

# 安装docker compose
sudo apt-get install -y docker-compose-plugin

# 启动docker
sudo systemctl start docker
sudo systemctl enable docker

# 完成
echo "Docker installed by Terraform" 