# terraform-cato-bulk-swp-rules

Bulk-manages the Cato **Site Web Proxy (siteWebProxy)** policy from a single
JSON export: sections and rules (flat policy - no sub-policies exist for this
type), with ordering and publishing via `cato_bulk_swp_move_rule`.

## Resources managed

| Resource | Keyed by | Notes |
|---|---|---|
| `cato_site_web_proxy_section.sections` | `section_name` | created `LAST_IN_POLICY`; ordered by the move resource |
| `cato_site_web_proxy_rule.rules` | rule name | placement: managed section -> `LAST_IN_SECTION`; sectionless -> `LAST_IN_POLICY` |
| `cato_bulk_swp_move_rule.all_swp_rules` | - | orders sections (`section_index`) and rules (`index_in_section`) and **publishes** |
| `cato_site_web_proxy_policy.policy` | - | optional account-level enable/disable toggle (`policy_enabled` variable) |

**Publishing:** the rule/section resources save to the draft policy only -
`cato_bulk_swp_move_rule` is this stack's single publisher. Site Web Proxy ships
**disabled** on new tenants - set `policy_enabled = true` (or enable it in
the CMA) for published rules to take effect.

**Note:** `cato_site_web_proxy_rule` ships in this module's HCL, but it is not
yet a released, importable provider resource - see "Importing Existing Rules
into Terraform State" below for the exact limitation and current workaround.

## Usage

The module reads a JSON configuration file that defines:
- **Rules**: Individual Site Web Proxy rules with their configurations
- **Sections**: Logical groupings for organizing rules
- **Rule ordering**: Defines which rules belong to which sections and their order within sections

### Basic Example

```hcl
module "swp_rules" {
  source                   = "catonetworks/bulk-swp-rules/cato"
  swp_rules_json_file_path = "${path.module}/config_data/all_swp_rules_and_sections.json"
}
```

### JSON Configuration Structure

The JSON file should contain a nested structure with the following key components:

- `data.policy.siteWebProxy.policy.rules[]` - Array of Site Web Proxy rules
- `data.policy.siteWebProxy.policy.sections[]` - Array of sections with index and name
- `data.policy.siteWebProxy.policy.rules_in_sections[]` - Mapping of rules to sections with ordering

#### Key Fields:

**Rules Array**: Each rule is wrapped as `{audit, rule, properties}` (ids
retained for brownfield import) and carries: `name`, `enabled`, `fqdn`,
`port`, `allowedDestinationProtocol`, `shouldAssociateWithAllSites`,
`associatedSite` (site refs by `name` or `id`), and `authenticationConfig`
(Kerberos; the encrypted keytab field is write-only, so it never round-trips
through export).

**Sections Array**: Defines sections with:
- `section_index`: The order of the section in the policy
- `section_name`: The display name of the section

**Rules in Sections Array**: Maps rules to sections with:
- `index_in_section`: The order of the rule within its section
- `section_name`: The section this rule belongs to (`""` for rules at the policy root)
- `rule_name`: The name of the rule to place in the section

### How Rule Ordering Works

`cato_bulk_swp_move_rule.all_swp_rules` reads `section_index` (from
`sections[]`) and `index_in_section` (from `rules_in_sections[]`) to order
sections and the rules within them, then republishes the policy on every
apply. Rows in `rules_in_sections[]` with `section_name: ""` have no managed
section to order within - they're excluded from the move resource, left in
creation order, and surfaced via the `unordered_rules` output for visibility.

### Parameters

- `swp_rules_json_file_path`: Path to the Site Web Proxy JSON export produced by `catocli export swp_rules` (`data.policy.siteWebProxy.policy` root)
- `policy_enabled`: (Optional) Manage the account-level Site Web Proxy policy toggle. `null` leaves the toggle unmanaged; `true`/`false` manages it via `cato_site_web_proxy_policy`
- `allow_empty_policy`: (Optional) Safety guard - fail planning when the policy JSON contains 0 rules unless explicitly allowed. Set `true` only for intentional greenfield/teardown

## Working with Existing Rules (Brownfield Deployments)

For brownfield deployments where you have an existing Site Web Proxy policy in your Cato Management Application, you can use the Cato CLI to export and import it into Terraform state.

### Installing and Configuring Cato CLI

1. **Install the Cato CLI:**
   ```bash
   pip3 install catocli
   ```

2. **Configure the CLI with your Cato credentials:**
   ```bash
   catocli configure set
   ```
   This will prompt you for your Cato Management Application credentials and account information.

### Exporting Existing Rules

To export your existing Site Web Proxy sections and rules into the JSON format required by this module:

```bash
catocli export swp_rules --json-filename all_swp_rules_and_sections.json
```

This command will generate a JSON file containing your existing Site Web Proxy policy (sections and rules) in the correct format for this Terraform module.

### Importing Existing Rules into Terraform State (native import blocks)

Requires Terraform **>= 1.7**. Every `for_each` address in this module
(`rules_by_name`, `sections_data`) is keyed by name, exactly matching the
exported JSON's `rule.name` / `section_name` fields - that's why the import
block below lines up one-to-one with the JSON with no re-keying.

**Rule import is not currently possible.** As of this writing,
`cato_site_web_proxy_rule` has no `ImportState` support because it isn't a
released resource at all - checking the provider source
(`terraform-provider-cato`) shows only `cato_site_web_proxy_section` is
registered; the rule resource exists only on an in-progress branch, held
back pending a server-side `addRule` API defect. Both options below
therefore cover **sections only**. Re-check the provider CHANGELOG before
assuming rule import (or even `cato_site_web_proxy_rule` itself) is
available - don't invent an import block for it until the resource ships.

<details>
<summary>Option A (recommended) - native Terraform import blocks (migration.tf)</summary>

```hcl
# migration.tf - one-time adoption of existing Site Web Proxy sections.
# Place beside the module call (same directory as main.tf), run once, then delete.
# NOTE: sections only - cato_site_web_proxy_rule has no ImportState support (see above).

locals {
  swp_migration_json     = jsondecode(file("${path.module}/config_data/all_swp_rules_and_sections.json"))
  swp_migration_policy   = local.swp_migration_json.data.policy.siteWebProxy.policy
  swp_migration_sections = { for s in local.swp_migration_policy.sections : s.section_name => s.section_id }
}

import {
  for_each = local.swp_migration_sections
  to       = module.swp_rules.cato_site_web_proxy_section.sections[each.key]
  id       = each.value
}
```

Preview the adoption before anything touches state:

```bash
terraform plan
```

Expect `N to import, 0 to add, 0 to change, 0 to destroy`. Any non-zero "to change" means the JSON export is stale relative to the live policy - **re-export** (`catocli export swp_rules --json-filename all_swp_rules_and_sections.json`) and regenerate the locals above, rather than letting `terraform apply` overwrite the live policy with stale config.

Once the plan is clean, adopt the resources into state:

```bash
terraform apply
```

`cato_bulk_swp_move_rule` is plan-time orchestration - it republishes the
whole policy on every apply and has no persisted object of its own to
import, so it never appears in `migration.tf`. Same for the optional
`cato_site_web_proxy_policy` enable/disable toggle: it's a tenant-wide
singleton with no name/`for_each` to key an import block on.

Then delete `migration.tf` - its job is done, and leaving it in place just re-runs the same (no-op) import blocks on every future plan.

</details>

<details>
<summary>Option B - catocli import swp_rules_to_tf (imperative alternative)</summary>

An imperative alternative to Option A, for when native import blocks aren't practical (e.g. scripting a fully automated onboarding pipeline). Unlike Option A, this mutates Terraform state immediately - there is no plan preview before the import happens.

```bash
catocli import swp_rules_to_tf config_data/all_swp_rules_and_sections.json \
  --module-name module.swp_rules --auto-approve
terraform plan   # expect: only cato_bulk_swp_move_rule to add
```

**Parameters:**
- `config_data/all_swp_rules_and_sections.json`: Path to your exported JSON file
- `--module-name module.swp_rules`: The name of your Terraform module instance

It's also subject to the same rule-import caveat above - it can only bring
sections under management until `cato_site_web_proxy_rule` ships.

</details>

### Typical Brownfield Workflow

1. **Export existing sections and rules:**
   ```bash
   catocli export swp_rules --json-filename all_swp_rules_and_sections.json
   ```

2. **Create your Terraform configuration:**
   ```hcl
   module "swp_rules" {
     source                   = "catonetworks/bulk-swp-rules/cato"
     swp_rules_json_file_path = "./config_data/all_swp_rules_and_sections.json"
   }
   ```

3. **Adopt existing state (Option A - recommended):** create `migration.tf` with the import blocks shown above, then:
   ```bash
   terraform plan    # preview: expect only "to import"
   terraform apply   # adopt into state
   ```
   Delete `migration.tf` afterwards. (Option B: `catocli import swp_rules_to_tf config_data/all_swp_rules_and_sections.json --module-name module.swp_rules` - imperative, no plan preview.)

4. **Run Terraform plan to verify:**
   ```bash
   terraform plan
   ```
   This should show no changes to sections if the import was successful (rules remain outside Terraform state until `cato_site_web_proxy_rule` ships).

### Backup and Restore Workflow

If unintended changes are made directly to sections in the Cato Management Application, you can restore to the last known good state:

1. **Apply your last known good configuration:**
   ```bash
   terraform apply
   ```
   This will restore managed sections (and ordering, via `cato_bulk_swp_move_rule`) to match your Terraform configuration. Rules are not covered, since `cato_site_web_proxy_rule` is not yet a released, stateful resource - see the rule-import limitation above.

2. **Alternatively, re-export and compare:**
   ```bash
   catocli export swp_rules --json-filename all_swp_rules_and_sections.json
   # Compare with your existing JSON file to identify changes
   ```

## Using Module Outputs

The module provides outputs that can be used for monitoring, auditing, integration with other systems, and operational insights. Below are practical examples of how to use these outputs in your Terraform configuration.

<details>
<summary>Click to expand example client-side outputs</summary>

```hcl
# Basic deployment information
output "deployment_info" {
  description = "Basic information about the Site Web Proxy deployment"
  value = {
    total_sections = module.swp_rules.deployment_summary.sections
    total_rules    = module.swp_rules.deployment_summary.rules
  }
}

# Quick reference for rule and section IDs
output "quick_reference" {
  description = "Quick reference maps for rules and sections"
  value = {
    section_ids = module.swp_rules.section_ids
    rule_ids    = module.swp_rules.rule_ids
  }
}

# Rows the move resource could not order (section_name "" in rules_in_sections)
output "rows_needing_attention" {
  description = "Example of surfacing rules_in_sections rows this module could not order"
  value = {
    unordered_rules       = module.swp_rules.unordered_rules
    unordered_rules_count = length(module.swp_rules.unordered_rules)
  }
}

# Example: For integration with monitoring systems
output "monitoring_metrics" {
  description = "Example metrics that could be sent to monitoring systems"
  value = {
    deployment_timestamp = timestamp()
    total_swp_sections    = module.swp_rules.deployment_summary.sections
    total_swp_rules       = module.swp_rules.deployment_summary.rules
    unordered_rule_count  = length(module.swp_rules.unordered_rules)
  }
}
```
</details>

### Output Use Cases

These example outputs demonstrate various practical applications:

- **`deployment_info`**: Quick deployment overview for dashboards
- **`quick_reference`**: ID mappings for referencing resources in other modules
- **`rows_needing_attention`**: Identifying ordering rows this module could not place under a managed section
- **`monitoring_metrics`**: Metrics formatted for monitoring systems

## Known limitations

- Ordering rows with `section_name: ""` are excluded from the move resource
  and surfaced via `unordered_rules`; their order is creation order.
- Run applies with `-parallelism=1` when several module instances share an
  account.
- `cato_site_web_proxy_rule` is not a released provider resource as of this
  writing (blocked upstream on an API `addRule` defect) - only
  `cato_site_web_proxy_section` supports import today.
- `cato_bulk_swp_move_rule` and the `cato_site_web_proxy_policy` toggle are
  outside the JSON-driven import flow regardless (see above).

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
|------|---------|
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.5.0 |
| <a name="requirement_cato"></a> [cato](#requirement\_cato) | >= 1.3.1 |

## Providers

| Name | Version |
|------|---------|
| <a name="provider_cato"></a> [cato](#provider\_cato) | 1.3.1 |
| <a name="provider_terraform"></a> [terraform](#provider\_terraform) | n/a |

## Modules

No modules.

## Resources

| Name | Type |
|------|------|
| [cato_bulk_swp_move_rule.all_swp_rules](https://registry.terraform.io/providers/catonetworks/cato/latest/docs/resources/bulk_swp_move_rule) | resource |
| [cato_site_web_proxy_policy.policy](https://registry.terraform.io/providers/catonetworks/cato/latest/docs/resources/site_web_proxy_policy) | resource |
| [cato_site_web_proxy_rule.rules](https://registry.terraform.io/providers/catonetworks/cato/latest/docs/resources/site_web_proxy_rule) | resource |
| [cato_site_web_proxy_section.sections](https://registry.terraform.io/providers/catonetworks/cato/latest/docs/resources/site_web_proxy_section) | resource |
| [terraform_data.guard_empty_policy](https://registry.terraform.io/providers/hashicorp/terraform/latest/docs/resources/data) | resource |

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| <a name="input_allow_empty_policy"></a> [allow\_empty\_policy](#input\_allow\_empty\_policy) | Safety guard: fail planning when the policy JSON contains 0 rules unless explicitly allowed. Protects against a truncated or wrong-tenant export destroying the live policy. Set true only for intentional greenfield/teardown. | `bool` | `false` | no |
| <a name="input_policy_enabled"></a> [policy\_enabled](#input\_policy\_enabled) | Manage the account-level Site Web Proxy policy toggle. null leaves the toggle unmanaged; true/false manages it via cato\_site\_web\_proxy\_policy. | `bool` | `null` | no |
| <a name="input_swp_rules_json_file_path"></a> [swp\_rules\_json\_file\_path](#input\_swp\_rules\_json\_file\_path) | Path to the Site Web Proxy JSON export produced by `catocli export swp_rules` (data.policy.siteWebProxy.policy root). | `string` | n/a | yes |

## Outputs

| Name | Description |
|------|-------------|
| <a name="output_deployment_summary"></a> [deployment\_summary](#output\_deployment\_summary) | Counts of managed Site Web Proxy objects. |
| <a name="output_rule_ids"></a> [rule\_ids](#output\_rule\_ids) | Map of rule name to rule id. |
| <a name="output_section_ids"></a> [section\_ids](#output\_section\_ids) | Map of section name to section id. |
| <a name="output_unordered_rules"></a> [unordered\_rules](#output\_unordered\_rules) | rules\_in\_sections rows excluded from cato\_bulk\_swp\_move\_rule (no managed section to order within). |
<!-- END_TF_DOCS -->
