#checkov:skip=CKV2_AWS_34: This reusable module supports both SecureString secrets and non-secret String parameters by design.
resource "aws_ssm_parameter" "this" {
  for_each = var.parameters

  name   = each.value.name
  type   = each.value.type
  value  = each.value.value
  key_id = each.value.key_id != null && each.value.key_id != "" ? each.value.key_id : null

  tags = var.tags
}
