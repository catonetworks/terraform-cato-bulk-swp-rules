# terraform-cato-bulk-swp-rules
#
# Bulk-manages the Cato Site Web Proxy (siteWebProxy) policy from one JSON
# export produced by `catocli export swp_rules`:
#   sections[] / rules[] / rules_in_sections[] - flat policy, no sub-policies.
# cato_bulk_swp_move_rule applies ordering and republishes.
# Rule fields: fqdn, port, allowedDestinationProtocol, shouldAssociateWithAllSites, associatedSite refs, authenticationConfig (Kerberos; encrypted keytab is write-only).

locals {
  swp_json = jsondecode(file("${var.swp_rules_json_file_path}"))
  swp      = local.swp_json.data.policy.siteWebProxy.policy

  sections_data_raw      = try(local.swp.sections, [])
  rules_data_raw         = try(local.swp.rules, [])
  rules_in_sections_data = try(local.swp.rules_in_sections, [])

  sections_data = {
    for s in local.sections_data_raw : s.section_name => s
  }

  rules_by_name = {
    for rw in local.rules_data_raw : rw.rule.name => rw
  }

  move_section_data = {
    for name, s in local.sections_data : name => {
      section_index = s.section_index
    }
  }

  move_rule_data = {
    for row in local.rules_in_sections_data :
    row.rule_name => {
      index_in_section = row.index_in_section
      section_name     = row.section_name
    }
    if row.section_name != "" && contains(keys(local.sections_data), row.section_name)
  }

  unordered_rules_data = [
    for row in local.rules_in_sections_data : row
    if !contains(keys(local.move_rule_data), try(row.rule_name, ""))
  ]

  rule_bodies = {
    for name, rw in local.rules_by_name : name => merge(
      {
        name    = rw.rule.name
        enabled = try(rw.rule.enabled, true)
        fqdn    = rw.rule.fqdn
        port    = tostring(rw.rule.port)
      },
      try(rw.rule.description, "") != "" ? { description = rw.rule.description } : {},
      try(rw.rule.allowedDestinationProtocol, null) != null ? { allowed_destination_protocol = rw.rule.allowedDestinationProtocol } : {},
      try(rw.rule.shouldAssociateWithAllSites, null) != null ? { should_associate_with_all_sites = rw.rule.shouldAssociateWithAllSites } : {},
      try(length(rw.rule.associatedSite), 0) > 0 ? { associated_site = [for x in rw.rule.associatedSite : can(x.name) ? { name = x.name } : { id = x.id }] } : {},
      try(rw.rule.authenticationConfig, null) != null ? {
        authentication_config = merge(
          try(rw.rule.authenticationConfig.method, null) != null ? { method = rw.rule.authenticationConfig.method } : {},
          try(rw.rule.authenticationConfig.kerberosConfig, null) != null ? {
            kerberos_config = { is_enabled = rw.rule.authenticationConfig.kerberosConfig.isEnabled }
          } : {}
        )
      } : {}
    )
  }
}

# Safety guard: fail `plan` early if the decoded rules list is empty, unless
# the caller explicitly opts in. Protects against a truncated export, a
# renamed upstream JSON key, or a wrong-tenant JSON file silently destroying
# every live rule via for_each. No provider/count/for_each here on purpose -
# the precondition must evaluate even with zero instances elsewhere.
resource "terraform_data" "guard_empty_policy" {
  lifecycle {
    precondition {
      condition     = var.allow_empty_policy || length(local.rules_by_name) > 0
      error_message = "Policy JSON contains 0 rules. If intentional (greenfield/teardown), set allow_empty_policy = true. A truncated or wrong-tenant export would otherwise destroy the entire live policy."
    }
  }
}

# Optional account-level policy toggle (Site Web Proxy ships disabled on new
# tenants - without enabling it, published rules have no effect).
resource "cato_site_web_proxy_policy" "policy" {
  count   = var.policy_enabled == null ? 0 : 1
  enabled = var.policy_enabled
}

resource "cato_site_web_proxy_section" "sections" {
  for_each = local.sections_data
  at = {
    position = "LAST_IN_POLICY"
  }
  section = {
    name = each.value.section_name
  }
}

resource "cato_site_web_proxy_rule" "rules" {
  depends_on = [cato_site_web_proxy_section.sections]
  for_each   = local.rules_by_name

  at = contains(keys(local.sections_data), each.value.rule.section.name) ? {
    position = "LAST_IN_SECTION"
    ref      = cato_site_web_proxy_section.sections[each.value.rule.section.name].id
    } : {
    position = "LAST_IN_POLICY"
  }

  rule = local.rule_bodies[each.key]
}

# Ordering + republish on changes.
resource "cato_bulk_swp_move_rule" "all_swp_rules" {
  depends_on = [cato_site_web_proxy_section.sections, cato_site_web_proxy_rule.rules]

  section_data = local.move_section_data
  rule_data    = local.move_rule_data
}
