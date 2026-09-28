variable "project" {
  description = "Short project/app name used in resource naming."
  type        = string
  default     = "inspire-app1"
}

variable "environment" {
  description = "Deployment environment (dev, staging, production)."
  type        = string
}

variable "location" {
  description = "Azure region."
  type        = string
  default     = "uksouth"
}

variable "container_image" {
  description = "Initial placeholder image. The app deploy pipeline owns the tag after first apply (see lifecycle block on azurerm_container_app.this)."
  type        = string
  default     = "mcr.microsoft.com/azuredocs/containerapps-helloworld:latest"
}
