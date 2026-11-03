variable "swp_rules_json_file_path" {
  description = "Path to the Site Web Proxy JSON export produced by `catocli export swp_rules` (data.policy.siteWebProxy.policy root)."
  type        = string
}

variable "policy_enabled" {
  description = "Manage the account-level Site Web Proxy policy toggle. null leaves the toggle unmanaged; true/false manages it via cato_site_web_proxy_policy."
  type        = bool
  default     = null
}
