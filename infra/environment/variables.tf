variable "project" {
  description = "Short project/app name. Must match the platform layer's var.project, it's how this layer finds the shared resource group, ACR and Container Apps Environment."
  type        = string
  default     = "inspire-app1"
}

variable "environment" {
  description = "Which Container App this state manages: staging or production. Not to be confused with the GitHub Environments (infra-apply, infra-apply-production, app-deploy-production), which are approval gates only."
  type        = string

  validation {
    condition     = contains(["staging", "production"], var.environment)
    error_message = "environment must be \"staging\" or \"production\"."
  }
}

variable "container_image" {
  description = "Initial placeholder image. The app deploy pipeline owns the tag after first apply (see lifecycle block on azurerm_container_app.this)."
  type        = string
  default     = "mcr.microsoft.com/azuredocs/containerapps-helloworld:latest"
}
