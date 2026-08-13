#!/usr/bin/env bash
#
# 票 01 — 把 VM 105 改名為 type-ai-platform-uat。
#
# 純標籤變更：不重啟、不動網路、不動磁碟、不動電源狀態。
# 在 PVE host 上以 root 執行。

set -euo pipefail
# shellcheck source=wizard.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/wizard.sh"

TOTAL_STAGES=5
banner "票 01 — VM ${UAT_VMID} 改名為 ${UAT_NEW_NAME}"

# ── 1 ─────────────────────────────────────────────────────────────────────
stage "前置檢查"
need_pve
qm config "$UAT_VMID" >/dev/null 2>&1 || abort "找不到 VM ${UAT_VMID}"

current_name=$(qmcfg "$UAT_VMID" name)
if [[ "$current_name" == "$UAT_NEW_NAME" ]]; then
  ok "VM ${UAT_VMID} 已經是 ${UAT_NEW_NAME}，無須改名"
  finish "票 01 hypervisor 端已完成"
  exit 0
fi
readback "VM ${UAT_VMID} 目前名稱" "$UAT_OLD_NAME" "$current_name"

before_status=$(qmstatus "$UAT_VMID")
say "目前電源狀態：${before_status}"

# ── 2 ─────────────────────────────────────────────────────────────────────
stage "記錄改名前的完整設定"
baseline=$(mktemp "/tmp/vm${UAT_VMID}-config-before.XXXXXX")
after=$(mktemp "/tmp/vm${UAT_VMID}-config-after.XXXXXX")
configdiff=$(mktemp "/tmp/vm${UAT_VMID}-config-diff.XXXXXX")
trap 'rm -f "$baseline" "$after" "$configdiff"' EXIT

qm config "$UAT_VMID" > "$baseline"
ok "已寫入 ${baseline}"
note "改名後會以此檔逐行比對，確認只有 name 改變。"
say ""
say "設定摘要："
grep -E '^(name|net[0-9]|ipconfig[0-9]|memory|balloon|cores|onboot|scsi|virtio|ide|sata|efidisk|boot):' \
  "$baseline" | sed 's/^/    /'

# ── 3 ─────────────────────────────────────────────────────────────────────
stage "改名"
say "將 VM ${UAT_VMID} 的名稱由 ${UAT_OLD_NAME} 改為 ${UAT_NEW_NAME}。"
note "這只更新 PVE 的顯示名稱，不觸發重啟，也不改變 guest 的 hostname。"
gate "執行改名？"

qm set "$UAT_VMID" --name "$UAT_NEW_NAME"
readback "VM ${UAT_VMID} 名稱" "$UAT_NEW_NAME" "$(qmcfg "$UAT_VMID" name)"

# ── 4 ─────────────────────────────────────────────────────────────────────
stage "確認其餘設定未被更動"
qm config "$UAT_VMID" > "$after"

if diff <(grep -v '^name: ' "$baseline") <(grep -v '^name: ' "$after") > "$configdiff"; then
  ok "除 name 外，設定逐行相同"
else
  warn "偵測到 name 以外的差異："
  sed 's/^/    /' "$configdiff"
  abort "改名不應改變其他設定"
fi

readback "電源狀態" "$before_status" "$(qmstatus "$UAT_VMID")"

# ── 5 ─────────────────────────────────────────────────────────────────────
stage "驗證 UAT 入口未受影響"
verify_uat_entrance

finish "票 01 hypervisor 端完成：VM ${UAT_VMID} = ${UAT_NEW_NAME}"
