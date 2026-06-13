variable "region" {
  type    = string
  default = "us-east-1"
}

variable "project" {
  type    = string
  default = "myapp"
}

variable "image_uri" {
  type = string
}

variable "container_port" {
  type    = number
  default = 8081
}

variable "db_username" {
  type      = string
  sensitive = true
}