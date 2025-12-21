#!/bin/bash

RG="learn-cloud"
NSG_NAME="MyWebServerNSG"
DB_SERVER="rory-journal-db-32152"

MY_IP=$(curl -4 https://icanhazip.com)

if [ -z "$MY_IP" ]; then
  echo "Could not determine public IP address."
  exit 1
fi

echo "My public IP address is: $MY_IP"

echo "Updating NSG rules to allow access from $MY_IP..."
az network nsg rule update \
  --resource-group $RG \
  --nsg-name $NSG_NAME \
  --name Allow-My-IP-5432 \
  --priority 1001 \
  --source-address-prefixes ${MY_IP} \
  --output none

echo "NSG rules updated."

echo "Updating database server firewall rules to allow access from $MY_IP..."
az postgres server firewall-rule create \
  --resource-group $RG \
  --server-name $DB_SERVER \
  --rule-name AllowMyIP \
  --start-ip-address $MY_IP \
  --end-ip-address $MY_IP \
  --output none
echo "Database server firewall rules updated."