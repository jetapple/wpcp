# luci-app-wpcp

LuCI frontend for managing `wpcp-agent` on OpenWrt 23.x and later.

This package uses the modern LuCI architecture:

- `menu.d` JSON menu registration
- JavaScript view implementation
- rpcd ACL based access control

Legacy Lua controller + CBI is intentionally not used.

## Current scope (phase 1)

- Services -> WPCP page entry
- Enumerate `config instance` sections from `/etc/config/wpcp-agent`
- Show core instance fields (`interface`, `broker`, `port`, `config`, `auto`, `enabled`)
- Per-instance service actions (`start`, `stop`, `restart`, `reload`) via init script
- Per-instance peer table from JSON config (`<ifname>.peers`)
- Peer operations on JSON config:
  - add
  - edit
  - delete
  - enable/disable (`disabled: "0"|"1"`)

## Files

- `root/usr/share/luci/menu.d/luci-app-wpcp.json`
- `root/usr/share/rpcd/acl.d/luci-app-wpcp.json`
- `htdocs/luci-static/resources/view/wpcp/overview.js`

## Notes

- Peer "disabled" is a config-level policy flag and not a direct runtime deactivation command.
- Service actions are instance-scoped from the LuCI page (action target is the current UCI instance section).
- When using `fs.exec()` for instance-scoped init actions, rpcd ACL needs both `ubus.file.exec` and explicit `file` scope `exec` permission in table notation for the full command line pattern.

