variable "swp_rules_json_file_path" {
  description = "Path to the Site Web Proxy JSON export produced by `catocli export swp_rules` (data.policy.siteWebProxy.policy root)."
  type        = string
}

variable "policy_enabled" {
  description = "Manage the account-level Site Web Proxy policy toggle. null leaves the toggle unmanaged; true/false manages it via cato_site_web_proxy_policy."
  type        = bool
  default     = null
}

variable "allow_empty_policy" {
  description = "Safety guard: fail planning when the policy JSON contains 0 rules unless explicitly allowed. Protects against a truncated or wrong-tenant export destroying the live policy. Set true only for intentional greenfield/teardown."
  type        = bool
  default     = false
}
