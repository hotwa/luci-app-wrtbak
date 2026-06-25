# Agent Maintenance Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add machine-readable maintenance commands so Codex or other trusted operators can inspect wrtbak readiness, plan backups, and review restore archives without reading secrets or writing router configuration.

**Architecture:** Keep the existing BusyBox-compatible shell CLI as the public interface. Add one focused library, `agent.sh`, for JSON status/doctor/plan/restore-plan output, and wire it into `root/usr/bin/wrtbak`; docs describe the remote maintenance workflow and safety boundaries. Restore remains read-only planning only.

**Tech Stack:** POSIX shell/BusyBox ash, OpenWrt runtime tools (`tar`, `find`, `stat`, `apk`/`opkg` when present), Python only in local fixture tests for JSON assertions.

---

## File Structure

- Create `root/usr/lib/wrtbak/agent.sh`: JSON emitters for `status`, `doctor`, `plan`, and `restore-plan`; no file restore writes.
- Modify `root/usr/bin/wrtbak`: source `agent.sh`, update usage, add parsers for the four new commands.
- Modify `docs/DEVELOPMENT.md`: include the new library and test command.
- Create `docs/AGENT_MAINTENANCE.md`: operator runbook for remote Codex-style maintenance.
- Create tests:
  - `tests/test_agent_status_fixture.sh`
  - `tests/test_agent_plan_fixture.sh`
  - `tests/test_restore_plan_fixture.sh`

## Chunk 1: Status And Doctor

### Task 1: Add Read-Only Agent Status And Doctor

**Files:**
- Create: `root/usr/lib/wrtbak/agent.sh`
- Modify: `root/usr/bin/wrtbak`
- Test: `tests/test_agent_status_fixture.sh`

- [x] **Step 1: Write the failing status/doctor fixture test**

Create `tests/test_agent_status_fixture.sh` with a fixture OpenWrt root containing `/etc/config/system`, `/etc/config/network`, `/etc/openwrt_release`, and `/etc/board.json`. Stub `apk info` in a temporary `bin` directory.

Expected assertions:
- `wrtbak status --json` emits valid JSON.
- JSON includes `tool_version`, `root`, `package_manager`, `device.hostname`, `device.management_ip`, `firmware.distribution`, and `counts.detected_items`.
- JSON includes a `recent_backups` array and does not include file contents.
- `wrtbak doctor --json` emits checks named `libdir`, `paths_file`, `output_dir`, `package_manager`, and `archive_tools`, each with `ok` boolean.

- [x] **Step 2: Run test to verify it fails**

Run:

```sh
sh tests/test_agent_status_fixture.sh
```

Expected: FAIL because `status` and `doctor` are unknown commands.

- [x] **Step 3: Implement minimal status/doctor support**

Add `root/usr/lib/wrtbak/agent.sh` with:
- `wrtbak_agent_status_json`
- `wrtbak_agent_doctor_json`
- small JSON helper emitters for arrays and checks

Wire into `root/usr/bin/wrtbak`:
- source `agent.sh`
- usage lines
- `status --json`
- `doctor --json`

- [x] **Step 4: Run test to verify it passes**

Run:

```sh
sh tests/test_agent_status_fixture.sh
```

Expected: PASS.

## Chunk 2: Backup Plan

### Task 2: Add Machine-Readable Backup Dry Run

**Files:**
- Modify: `root/usr/lib/wrtbak/agent.sh`
- Modify: `root/usr/bin/wrtbak`
- Test: `tests/test_agent_plan_fixture.sh`

- [x] **Step 1: Write the failing backup-plan fixture test**

Create a fixture with known files under `/etc/config/system`, `/etc/config/network`, and `/etc/nikki`. Assert:
- `wrtbak plan --profile agent-test --items core-system,nikki --format wrtbak --json` emits valid JSON.
- JSON includes `profile`, `format`, `items`, `paths`, `summary.existing_paths`, `summary.missing_paths`, `summary.sensitive_items`, and `warnings`.
- Existing paths are listed without content.
- Missing configured paths are listed as paths only.
- Invalid profile/items/format are rejected.

- [x] **Step 2: Run test to verify it fails**

Run:

```sh
sh tests/test_agent_plan_fixture.sh
```

Expected: FAIL because `plan` is unknown.

- [x] **Step 3: Implement minimal plan support**

Add `wrtbak_agent_plan_json` and parser:

```sh
wrtbak plan --profile NAME --items IDS --format wrtbak|sysupgrade --json
```

Use existing `wrtbak_validate_profile_name`, `wrtbak_validate_item_ids`, `wrtbak_write_paths_for_items`, `wrtbak_item_paths_by_id`, and path helpers. Do not read or print file contents.

- [x] **Step 4: Run test to verify it passes**

Run:

```sh
sh tests/test_agent_plan_fixture.sh
```

Expected: PASS.

## Chunk 3: Restore Plan

### Task 3: Add Read-Only Restore Archive Plan

**Files:**
- Modify: `root/usr/lib/wrtbak/agent.sh`
- Modify: `root/usr/bin/wrtbak`
- Test: `tests/test_restore_plan_fixture.sh`

- [x] **Step 1: Write the failing restore-plan fixture test**

Create a `.wrtbak` fixture with the existing CLI, then assert:
- `wrtbak restore-plan --input FILE --json` emits valid JSON.
- JSON includes `archive`, `schema`, `profile`, `backup_id`, `created_at`, `tool_version`, `file_count`, `directory_count`, `total_file_bytes`, `restart_services`, `reboot_recommended`, `requires_confirmation`, and `paths`.
- Unsafe archives fail before JSON is emitted.
- The command does not write under `WRTBAK_ROOT`.

- [x] **Step 2: Run test to verify it fails**

Run:

```sh
sh tests/test_restore_plan_fixture.sh
```

Expected: FAIL because `restore-plan` is unknown.

- [x] **Step 3: Implement minimal restore-plan support**

Add `wrtbak_agent_restore_plan_json`:
- reuse `wrtbak_validate_archive_metadata`
- extract only into a temporary directory
- read `manifest.json`
- emit summary from manifest and inventory-like data
- never copy files to target root

- [x] **Step 4: Run test to verify it passes**

Run:

```sh
sh tests/test_restore_plan_fixture.sh
```

Expected: PASS.

## Chunk 4: Documentation And Full Verification

### Task 4: Document Agent Maintenance Workflow

**Files:**
- Create: `docs/AGENT_MAINTENANCE.md`
- Modify: `docs/DEVELOPMENT.md`

- [x] **Step 1: Document remote maintenance commands**

Cover:
- `ssh root@router wrtbak status --json`
- `wrtbak doctor --json`
- `wrtbak plan ... --json`
- `wrtbak create-download ...`
- `wrtbak restore-plan --input ... --json`
- Explicit restore safety boundary: review first, use OpenWrt `sysupgrade -r` only after human confirmation.

- [x] **Step 2: Run all local checks**

Run:

```sh
sh -n root/usr/bin/wrtbak root/usr/lib/wrtbak/*.sh tests/*.sh
for test_script in tests/*.sh; do sh "$test_script"; done
git diff --check
```

Expected: all commands exit 0.

- [ ] **Step 3: Commit and push**

Commit:

```sh
git add root/usr/bin/wrtbak root/usr/lib/wrtbak/agent.sh tests/test_agent_status_fixture.sh tests/test_agent_plan_fixture.sh tests/test_restore_plan_fixture.sh docs/AGENT_MAINTENANCE.md docs/DEVELOPMENT.md docs/superpowers/plans/2026-06-25-agent-maintenance.md
git commit -m "feat: add agent maintenance commands"
git push -u origin codex/agent-maintenance
```
