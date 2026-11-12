variable "name" {
  type = string
}

variable "domain" {
  type = string
}

variable "size" {
  type    = string
  default = "s"
  validation {
    condition     = contains(["s", "m"], var.size)
    error_message = "size must be s or m"
  }
}

variable "db_instances" {
  type    = number
  default = 1
}

variable "db_cluster" {
  type    = string
  default = "primary"
  validation {
    condition     = contains(["primary", "restore"], var.db_cluster)
    error_message = "db_cluster must be primary or restore"
  }
}

variable "restore_target_time" {
  type    = string
  default = null
}

variable "chart_path" {
  type = string
}