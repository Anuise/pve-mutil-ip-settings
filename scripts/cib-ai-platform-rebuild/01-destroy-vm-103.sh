#!/usr/bin/env bash
#
# 票 01 — 銷毀 VM 103。不保全、不備份（ADR-0006）。
#
# 這是不可逆的一步，而且前面沒有任何準備票。使用者已在知道下面那份清單之後做出
# 決定，所以本腳本的工作是把清單完整攤開、要求雙重確認、然後執行 —— 不是以
# 「先備份吧」擋下來。
#
# 在 PVE host 上以 root 執行。

set -euo pipefail
# shellcheck source=wizard.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/wizard.sh"

TOTAL_STAGES=6
banner "票 01 — 銷毀 VM ${CIB_VMID}（不可逆、無備份）"

# ── 1 ─────────────────────────────────────────────────────────────────────
stage "前置檢查"
need_pve
vm_exists "$CIB_VMID" || abort "找不到 VM ${CIB_VMID}（已經銷毀過了？）"
init_report
readback "VM ${CIB_VMID} 名稱" "type-ai-platform-demo" "$(qmcfg "$CIB_VMID" name)"
note "名稱讀回是為了確認銷毀對象是舊的那一台，不是已經抽換過的新機器。"
say "執行紀錄：${REPORT}"

# ── 2 ─────────────────────────────────────────────────────────────────────
stage "將永久消失的東西"
say "磁碟："
qm config "$CIB_VMID" | grep -E '^(scsi|ide|sata|virtio|efidisk|tpmstate)[0-9]+:' |
  sed 's/^/    /'
say ""
say "快照：$(list_snapshots "$CIB_VMID")"
say ""
warn "以下沒有任何副本，銷毀後無法取回："
say "    · GitLab deploy key ${HOME_DIR}/.ssh/id_ed25519_mobagel_gitlab"
say "      —— 之後要 clone repo，必須有人去 GitLab 簽發新的一把"
say "    · /srv/typeai-demo/ 的五份 secret（demo-password、kc-admin-password、"
say "      kc-token、seed-client-secret、service-token-secret）"
say "    · /srv/typeai-demo/nginx.conf 與 試用說明.md"
say "    · Keycloak 的 typeai-demo-pg volume（66.65 MB）"
say ""
POOL_BEFORE=$(pool_free_gib "$DISK_STORAGE")
say "儲存池 ${DISK_STORAGE} 目前可用 ${POOL_BEFORE} GiB"
say ""
verify_uat_entrance

# ── 3 ─────────────────────────────────────────────────────────────────────
stage "停機"
note "停機不是為了備份一致性（這一輪沒有備份），是為了不在執行中的 guest 底下抽磁碟。"
if [[ "$(qmstatus "$CIB_VMID")" == "running" ]]; then
  gate "關閉 VM ${CIB_VMID}？"
  qm shutdown "$CIB_VMID" --timeout 300 || abort "qm shutdown 失敗；用 PVE console 檢查"
fi
readback "VM ${CIB_VMID} 電源狀態" "stopped" "$(qmstatus "$CIB_VMID")"

# ── 4 ─────────────────────────────────────────────────────────────────────
stage "雙重確認"
human_action "這一步之後沒有回頭路，而且這一輪沒有備份頂上。"
say ""
say "上面列出的磁碟、快照與那四類無副本的東西會全部消失。"
say "依 ADR-0006，這是已定案的決定；要改變主意，現在停止並改跑"
say ".scratch/demo-rebuild-from-template/ 的票 01 與 02。"
say ""
gate "清單看過了，確定不保全也不備份，要銷毀 VM ${CIB_VMID}？"
type_to_confirm "destroy ${CIB_VMID} without backup"

# ── 5 ─────────────────────────────────────────────────────────────────────
stage "移除 VM"
qm destroy "$CIB_VMID" --purge || abort "qm destroy 失敗"
ok "qm destroy 結束碼 0（結束碼不算證據，下一步才是）"

# ── 6 ─────────────────────────────────────────────────────────────────────
stage "讀回"
! vm_exists "$CIB_VMID" || abort "qm config ${CIB_VMID} 仍查得到，VMID 沒有空出來"
ok "qm config ${CIB_VMID} 查不到，VMID 已空出"

leftover=$(pvesm list "$DISK_STORAGE" 2>/dev/null | grep -c "vm-${CIB_VMID}-disk" || true)
if [[ "$leftover" != "0" ]]; then
  warn "儲存池上還有 ${leftover} 個 vm-${CIB_VMID}-disk-*（未被 config 引用）"
  pvesm list "$DISK_STORAGE" | grep "vm-${CIB_VMID}-disk" | sed 's/^/    /'
  note "本腳本不動它們。clone 會配置新名字，不受影響；要清掉請人工確認後處理。"
else
  ok "儲存池上沒有殘留的 vm-${CIB_VMID}-disk-*"
fi

POOL_AFTER=$(pool_free_gib "$DISK_STORAGE")
say "儲存池 ${DISK_STORAGE} 可用：${POOL_BEFORE} GiB → ${POOL_AFTER} GiB（釋出 $(( POOL_AFTER - POOL_BEFORE )) GiB）"
report_section "銷毀舊 VM ${CIB_VMID}（票 01）"
{
  printf '| 項目 | 值 |\n| --- | --- |\n'
  printf '| 備份 | 無（ADR-0006） |\n'
  printf '| 儲存池可用（前 / 後） | %s GiB / %s GiB |\n' "$POOL_BEFORE" "$POOL_AFTER"
  printf '| 殘留磁碟 | %s |\n' "$leftover"
} >> "$REPORT"

say ""
verify_uat_entrance

finish "票 01 完成：VMID ${CIB_VMID} 已空出"
say "下一步：./02-clone-from-template.sh"
