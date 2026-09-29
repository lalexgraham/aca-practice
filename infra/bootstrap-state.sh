#!/usr/bin/env bash
RESOURCE_GROUP_NAME=rg-tfstate
STORAGE_ACCOUNT_NAME=tfstate$RANDOM
CONTAINER_NAME=tfstate

# Create resource group
az group create --name $RESOURCE_GROUP_NAME --location uksouth

# Create storage account
az storage account create --resource-group $RESOURCE_GROUP_NAME --name $STORAGE_ACCOUNT_NAME --sku Standard_LRS --encryption-services blob

# Create blob container
az storage container create --name $CONTAINER_NAME --account-name $STORAGE_ACCOUNT_NAME

STORAGE_ACCOUNT_KEY=$(az storage account keys list \
  --resource-group $RESOURCE_GROUP_NAME \
  --account-name $STORAGE_ACCOUNT_NAME \
  --query '[0].value' -o tsv)

echo "State storage account name: $STORAGE_ACCOUNT_NAME"
echo "State storage account key: $STORAGE_ACCOUNT_KEY"
echo "Record this in backend.hcl and CI variables. Do not run this script again."