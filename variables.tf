
//
//  User Input
//

variable "timeout" {
  type = number
  default = 60
}

variable "memory" {
  type = number
  default = 256
}

variable "region" {
  type = string
  default = "us-east-1"
}

variable "envvars" {
  type = string
  default = "{}"
}


//
//  Exobase Provided
//

variable "exo_context" {
  type = string // json:DeploymentContext
}

variable "exo_profile" {
  type = string
}