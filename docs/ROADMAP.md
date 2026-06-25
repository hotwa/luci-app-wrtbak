# Roadmap

## v0.1

- CLI-oriented archive creation and validation.
- OpenWrt package skeleton.
- Documented `.wrtbak` and `.sysupgrade.tar.gz` formats.
- Installed package detection and selected-item archive creation.
- LuCI page for selecting backup items and downloading generated archives.
- Machine-readable agent maintenance commands for status, doctor, backup plan, and read-only restore plan.

## v0.2

- Restore review page for uploaded `.wrtbak` archives.
- Selective restore UI with manifest and device compatibility checks.
- rpcd/ubus integration for privileged restore operations.

## v0.3

- Rollback confirmation flow after restore.
- Safer restore checkpoints and user-visible recovery guidance.

## v0.4

- Desktop integration hooks for importing, exporting, and organizing backup archives outside the router UI.
