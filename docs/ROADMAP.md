# Roadmap

## v0.1

- CLI-oriented archive creation and validation.
- OpenWrt package skeleton.
- Documented `.wrtbak` and `.sysupgrade.tar.gz` formats.
- Installed package detection and selected-item archive creation.
- LuCI page for selecting backup items and downloading generated archives.
- Machine-readable agent maintenance commands for status, doctor, backup plan, and read-only restore plan.
- WebDAV and S3-compatible remote backup targets with LuCI configuration.
- CLI and LuCI operations for remote test, upload, list, delete, and retention pruning.
- Cron-backed automatic backup scheduling.
- Confirmed remote restore flow for WebDAV/S3 backups with restore review, mandatory pre-restore backup, explicit `RESTORE` confirmation, `.wrtbak` apply, and native sysupgrade handoff.

## v0.2

- Richer restore item selection in LuCI beyond the initial core-system/all buttons.
- Restore evidence export for operator review.
- Cross-device restore profiles with clearer compatibility policies.

## v0.3

- Rollback confirmation flow after restore.
- Safer restore checkpoints and user-visible recovery guidance.

## v0.4

- Desktop integration hooks for importing, exporting, and organizing backup archives outside the router UI.
