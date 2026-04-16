variable "parameters" {
  type = map(object({
    name   = string
    type   = string
    value  = string
    key_id = string
  }))
}

variable "tags" {
  type = map(string)
}
