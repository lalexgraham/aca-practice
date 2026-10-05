variable "project" {
  description = "Short project/app name used in resource naming. Must match the environment layer's var.project, which looks the platform resources up by name."
  type        = string
  default     = "inspire-app1"
}

variable "location" {
  description = "Azure region."
  type        = string
  default     = "uksouth"
}
