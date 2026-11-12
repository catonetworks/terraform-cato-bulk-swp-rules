# Changelog

## 0.0.1 (2026-11-04)

### Features
- Initial release: bulk management of Site Web Proxy (siteWebProxy)
  sections from a catocli JSON export, with name-keyed state addressing.
  Rule-level HCL (`cato_site_web_proxy_rule`) is present in the module but
  held back — the resource isn't yet supported pending an upstream
  provider/API fix, so this release manages sections only.
- Added `allow_empty_policy` safety guard — planning fails when the policy
  JSON contains 0 rules unless explicitly allowed, protecting against
  truncated or wrong-tenant exports mass-destroying a live policy.
- README: brownfield import documentation covers two options — native
  Terraform `import` blocks (recommended, declarative/previewable) and the
  `catocli import swp_rules_to_tf` imperative alternative.
