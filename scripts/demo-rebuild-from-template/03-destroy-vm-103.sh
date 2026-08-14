#!/usr/bin/env bash
#
# 票 03 — 銷毀舊的 VM 103，把 VMID 103 空出來。
#
# **本 spec 唯一不可逆的一步，也是分水嶺。** 之後每一張票都建立在「舊機器已經
# 不存在」之上。執行前逐項現場重算票 01 的保全產物，不採信上一次的紀錄。
#
# Blocked by 票 02。在 PVE host 上以 root 執行。

set -euo pipefail
# shellcheck source=wizard.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/wizard.sh"

HOST_DIR=$(preserve_dir)
REPORT="${HOST_DIR}/preserve-report.md"

TOTAL_STAGES=7
banner "票 03 — 銷毀 VM ${DEMO_VMID}（不可逆）"

# ── 1 ─────────────────────────────────────────────────────────────────────
stage "前置檢查"
need_pve
vm_exists "$DEMO_VMID" || abort "找不到 VM ${DEMO_VMID}（已經銷毀過了？）"
[[ -f "$REPORT" ]] || abort "找不到票 01／02 的報告 ${REPORT}"
say "保全目錄：${HOST_DIR}"

# ── 2 ─────────────────────────────────────────────────────────────────────
stage "現場重算票 01 的保全產物"
note "不採信上一次的紀錄：每一包都當場解開、逐檔重算 SHA-256。"
for name in ssh app; do
  [[ -f "${HOST_DIR}/${name}.tar" && -f "${HOST_DIR}/${name}.sha256" ]] ||
    abort "缺少 ${name}.tar 或 ${name}.sha256"
  tmp=$(mktemp -d)
  tar -C "$tmp" -xf "${HOST_DIR}/${name}.tar"
  ( cd "$tmp" && sha256sum -c "${HOST_DIR}/${name}.sha256" >/dev/null ) || {
    rm -rf "$tmp"; abort "${name}.tar 的逐檔 SHA-256 與票 01 的清單不符"
  }
  rm -rf "$tmp"
  ok "${name}.tar 逐檔相符（$(wc -l < "${HOST_DIR}/${name}.sha256") 個檔案）"
done

recorded=$(sed -n 's/^| 封存 SHA-256 | `\(.*\)` |$/\1/p' "$REPORT" | head -n1)
[[ -n "$recorded" ]] || abort "報告裡沒有 ${PG_VOLUME_TAR} 的 SHA-256"
readback "${PG_VOLUME_TAR} 的 SHA-256" "$recorded" \
  "$(sha256sum "${HOST_DIR}/${PG_VOLUME_TAR}" | cut -d' ' -f1)"

for f in "${SECRET_FILES[@]}" "${KEEP_FILES[@]}" "${SSH_FILES[@]}"; do
  [[ -e "${HOST_DIR}/app/${f}" || -e "${HOST_DIR}/ssh/${f}" ]] ||
    abort "保全清單少了 ${f} —— 不准銷毀 ${DEMO_VMID}"
done
ok "保全清單逐項都在（deploy key ${#SSH_FILES[@]} + secret ${#SECRET_FILES[@]} + 設定與文件 ${#KEEP_FILES[@]}）"

# ── 3 ─────────────────────────────────────────────────────────────────────
stage "票 02 的備份"
ARCHIVE=$(sed -n 's/^| 封存 | `\(.*\)` |$/\1/p' "$REPORT" | head -n1)
[[ -n "$ARCHIVE" ]] || abort "報告裡沒有 vzdump 封存路徑；票 02 沒跑完"
[[ -f "$ARCHIVE" ]] || abort "封存檔不存在：${ARCHIVE}"
bytes=$(stat -c %s "$ARCHIVE")
[[ "$bytes" -gt 0 ]] || abort "封存檔大小為 0"
say "封存：${ARCHIVE}（${bytes} bytes）"
zstd -l "$ARCHIVE" | sed 's/^/    /' || abort "封存內容列不出來 —— 不准銷毀 ${DEMO_VMID}"
ok "備份存在、大小不為 0、內容列得出來"

# ── 4 ─────────────────────────────────────────────────────────────────────
stage "將被刪除的東西"
readback "VM ${DEMO_VMID} 電源狀態" "stopped" "$(qmstatus "$DEMO_VMID")"
say ""
say "磁碟："
qm config "$DEMO_VMID" | grep -E '^(scsi|ide|sata|virtio|efidisk|tpmstate)[0-9]+:' |
  sed 's/^/    /'
say ""
say "快照：$(list_snapshots "$DEMO_VMID")"
say ""
POOL_BEFORE=$(pool_free_gib "$DISK_STORAGE")
say "儲存池 ${DISK_STORAGE} 目前可用 ${POOL_BEFORE} GiB"
say ""
verify_uat_entrance

# ── 5 ─────────────────────────────────────────────────────────────────────
stage "雙重確認"
human_action "這一步之後沒有回頭路。上面列出的磁碟與快照會全部消失。"
say ""
say "還能回頭的只剩兩份東西，兩份都已在上面驗過："
say "  · 保全產物 ${HOST_DIR}"
say "  · 全機備份 ${ARCHIVE}"
say ""
gate "保全與備份都確認過，要銷毀 VM ${DEMO_VMID}？"
type_to_confirm "destroy ${DEMO_VMID}"

# ── 6 ─────────────────────────────────────────────────────────────────────
stage "移除 VM"
qm destroy "$DEMO_VMID" --purge || abort "qm destroy 失敗"
ok "qm destroy 結束碼 0（結束碼不算證據，下一步才是）"

# ── 7 ─────────────────────────────────────────────────────────────────────
stage "讀回"
! vm_exists "$DEMO_VMID" || abort "qm config ${DEMO_VMID} 仍查得到，VMID 沒有空出來"
ok "qm config ${DEMO_VMID} 查不到，VMID 已空出"

leftover=$(pvesm list "$DISK_STORAGE" 2>/dev/null | grep -c "vm-${DEMO_VMID}-disk" || true)
if [[ "$leftover" != "0" ]]; then
  warn "儲存池上還有 ${leftover} 個 vm-${DEMO_VMID}-disk-* 磁碟（未被 config 引用）"
  pvesm list "$DISK_STORAGE" | grep "vm-${DEMO_VMID}-disk" | sed 's/^/    /'
  note "本腳本不動它們。clone 會另外配置新名字，不受影響；要清掉請人工確認後處理。"
else
  ok "儲存池上沒有殘留的 vm-${DEMO_VMID}-disk-*"
fi

POOL_AFTER=$(pool_free_gib "$DISK_STORAGE")
say "儲存池 ${DISK_STORAGE} 可用：${POOL_BEFORE} GiB → ${POOL_AFTER} GiB（釋出 $(( POOL_AFTER - POOL_BEFORE )) GiB）"
{
  printf '\n### 銷毀（票 03）\n\n'
  printf '| 項目 | 值 |\n| --- | --- |\n'
  printf '| 時間 | %s |\n' "$(date +%Y-%m-%dT%H:%M:%S%z)"
  printf '| 儲存池可用（前 / 後） | %s GiB / %s GiB |\n' "$POOL_BEFORE" "$POOL_AFTER"
  printf '| 殘留磁碟 | %s |\n' "$leftover"
} >> "$REPORT"

say ""
verify_uat_entrance

finish "票 03 完成：VMID ${DEMO_VMID} 已空出"
say "下一步：PRESERVE_DIR=${HOST_DIR} ./04-clone-from-template.sh"
