# 1. 配置 Azure 提供商
terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.0"
    }
    random = {
      source = "hashicorp/random" # 用来生成随机密码
    }
  }
}

provider "azurerm" {
  features {}
}

# 2. 创建资源组 (East US 最便宜)
resource "azurerm_resource_group" "rg" {
  name     = "journal-production-rg-v3"
  location = "Korea Central"
}

# 3. 网络基础设施 (VNet & Subnet)
resource "azurerm_virtual_network" "vnet" {
  name                = "journal-vnet"
  address_space       = ["10.0.0.0/16"]
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
}

resource "azurerm_subnet" "subnet" {
  name                 = "internal"
  resource_group_name  = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = ["10.0.1.0/24"]
}

# 4. 公网 IP (用于 VM)
resource "azurerm_public_ip" "public_ip" {
  name                = "journal-vm-ip"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  allocation_method   = "Static"   # 标准版必须是静态
  sku                 = "Standard" # 强制升级到标准版
}

# 5. 网络接口 (NIC)
resource "azurerm_network_interface" "nic" {
  name                = "journal-vm-nic"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.subnet.id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.public_ip.id
  }
}

# 6. 安全组 (防火墙) - 开放 22(SSH) 和 8000(API)
resource "azurerm_network_security_group" "nsg" {
  name                = "journal-nsg"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name

  security_rule {
    name                       = "SSH"
    priority                   = 1001
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "22"
    source_address_prefix      = "*" # 生产环境请改为你的 IP
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "FastAPI"
    priority                   = 1002
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "8000"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }
}

# 将 NSG 绑定到网卡
resource "azurerm_network_interface_security_group_association" "example" {
  network_interface_id      = azurerm_network_interface.nic.id
  network_security_group_id = azurerm_network_security_group.nsg.id
}

# 7. 生成 SSH 密钥 (免去手动创建的麻烦)
resource "tls_private_key" "example_ssh" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

# 8. 虚拟机 (Spot Instance - 极致省钱配置!)
resource "azurerm_linux_virtual_machine" "vm" {
  name                = "journal-vm-spot"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  size                = "Standard_B1s" # 最便宜的规格
  admin_username      = "azureuser"
  network_interface_ids = [
    azurerm_network_interface.nic.id,
  ]

  # 🔥 Spot 实例核心配置 🔥
  # priority        = "Spot"
  # eviction_policy = "Deallocate"
  # max_bid_price   = -1 # -1 表示愿意支付当前市场价

  admin_ssh_key {
    username   = "azureuser"
    public_key = tls_private_key.example_ssh.public_key_openssh
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS" # 拒绝 Premium SSD
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-jammy"
    sku       = "22_04-lts"
    version   = "latest"
  }
}

# 9. 数据库密码生成器 (安全!)
resource "random_password" "db_password" {
  length           = 16
  special          = true
  override_special = "!#$%&*()-_=+[]{}<>:?"
}

resource "random_string" "naming_suffix" {
  length  = 6
  special = false
  upper   = false
}

# 10. PostgreSQL 数据库 (省钱配置)
resource "azurerm_postgresql_flexible_server" "db" {
  name                   = "journal-db-${random_string.naming_suffix.result}" # 随机名字防冲突
  resource_group_name    = azurerm_resource_group.rg.name
  location               = azurerm_resource_group.rg.location
  version                = "13"
  administrator_login    = "roryadmin"
  administrator_password = random_password.db_password.result
  zone                   = "1"

  storage_mb = 32768

  sku_name   = "B_Standard_B1ms" # Burstable 规格
}

# 11. 数据库防火墙 (允许所有 IP - 方便调试，之后可收紧)
resource "azurerm_postgresql_flexible_server_firewall_rule" "allow_all" {
  name             = "AllowAll"
  server_id        = azurerm_postgresql_flexible_server.db.id
  start_ip_address = "0.0.0.0"
  end_ip_address   = "255.255.255.255"
}

# 12. 输出信息 (这样你就不用去 Portal 找 IP 和密码了)
output "public_ip" {
  value = azurerm_linux_virtual_machine.vm.public_ip_address
}

output "db_password" {
  value     = random_password.db_password.result
  sensitive = true # 敏感信息，默认不打印，用 terraform output 查看
}

output "db_host" {
  value = azurerm_postgresql_flexible_server.db.fqdn
}

output "private_key" {
  value     = tls_private_key.example_ssh.private_key_pem
  sensitive = true
}