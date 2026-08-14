#!/usr/bin/env bash
#
# 票 02 — 對 VM 103 做一次 vzdump 全機備份，並驗證它可讀。
#
# 票 01 保的是「知道自己需要的東西」；這一票保的是「銷毀之後才想起來的那些」。
# 快照 pre-demo-entrance-20260813 會跟著 qm destroy 一起消失，不算回復點。
#
# 備份在停機狀態做：不必處理一致性問題，而且此時已經沒有人在用這台機器。
# 備份不刪 —— 留到新機器通過票 07 的驗收，且使用者明確說可以刪為止。
#
# Blocked by 票 01。在 PVE host 上以 root 執行。

set -euo pipefail
# shellcheck source=wizard.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/wizard.sh"

HOST_DIR=$(preserve_dir)
REPORT="${HOST_DIR}/preserve-report.md"
LOG="${HOST_DIR}/vzdump.log"

TOTAL_STAGES=6
banner "票 02 — VM ${DEMO_VMID} 全機備份"

# ── 1 ─────────────────────────────────────────────────────────────────────
stage "前置檢查"
need_pve
vm_exists "$DEMO_VMID" || abort "找不到 VM ${DEMO_VMID}"
say "票 01 的保全目錄：${HOST_DIR}"
[[ -f "$REPORT" ]] || abort "${REPORT} 不存在；票 02 的記錄要跟票 01 的放在一起"
[[ -f "${HOST_DIR}/ssh.tar" && -f "${HOST_DIR}/app.tar" && -f "${HOST_DIR}/${PG_VOLUME_TAR}" ]] ||
  abort "保全目錄裡缺少票 01 的封存（ssh.tar／app.tar／${PG_VOLUME_TAR}）"
ok "票 01 的三個封存都在"

# ── 2 ─────────────────────────────────────────────────────────────────────
stage "停機"
if [[ "$(qmstatus "$DEMO_VMID")" == "running" ]]; then
  say "停機備份不必處理一致性問題，而且此時已經沒有人在用這台機器。"
  note "反向動作：qm start ${DEMO_VMID}。這一步還完全可逆。"
  gate "關閉 VM ${DEMO_VMID}？"
  qm shutdown "$DEMO_VMID" --timeout 300 ||
    abort "qm shutdown 失敗；不要改用 qm stop 強停，先查 guest 為何關不掉"
fi
for _ in $(seq 60); do
  [[ "$(qmstatus "$DEMO_VMID")" == "stopped" ]] && break
  sleep 5
done
readback "VM ${DEMO_VMID} 電源狀態" "stopped" "$(qmstatus "$DEMO_VMID")"

# ── 3 ─────────────────────────────────────────────────────────────────────
stage "存放區空間"
avail_gib=$(pool_free_gib "$BACKUP_STORAGE")
say "存放區 ${BACKUP_STORAGE} 可用 ${avail_gib} GiB"
# grep 沒有配對時會回 1，pipefail 下整個指派失敗、set -e 讓腳本靜默結束 ——
# 而這個數字只是印給人看的參考值，不該有停掉序列的權力。
declared_gib=$( { qm config "$DEMO_VMID" | grep -oE 'size=[0-9]+G' | grep -oE '[0-9]+' |
  awk '{s += $1} END {print s + 0}'; } || echo '?')
say "VM 磁碟宣告總量 ${declared_gib} GiB（zstd 壓縮後通常遠小於此）"
[[ "$avail_gib" -gt 100 ]] || abort "${BACKUP_STORAGE} 只剩 ${avail_gib} GiB，先騰出空間再備份"

# ── 4 ─────────────────────────────────────────────────────────────────────
stage "vzdump"
say "vzdump ${DEMO_VMID} --storage ${BACKUP_STORAGE} --compress zstd --mode stop"
note "整機磁碟要讀過一遍，視資料量可能要跑數十分鐘。中途 Ctrl-C 只會留下半份"
note "封存，重跑即可（PVE 會另存新檔，不覆蓋）。"
gate "開始備份？"

set +e
vzdump "$DEMO_VMID" --storage "$BACKUP_STORAGE" --compress zstd --mode stop \
  --notes-template 'before demo rebuild from template 109' 2>&1 | tee "$LOG"
rc=${PIPESTATUS[0]}
set -e
[[ "$rc" -eq 0 ]] || abort "vzdump 以 ${rc} 結束；封存不完整，不得繼續"
ok "vzdump 結束碼 0（結束碼不算證據，下一步才是）"

ARCHIVE=$(vzdump_archive_path < "$LOG") ||
  abort "vzdump 的輸出裡找不到封存路徑；檢查 ${LOG}"
say "封存：${ARCHIVE}"

# ── 5 ─────────────────────────────────────────────────────────────────────
stage "封存可讀"
[[ -f "$ARCHIVE" ]] || abort "封存檔不存在：${ARCHIVE}"
bytes=$(stat -c %s "$ARCHIVE")
[[ "$bytes" -gt 0 ]] || abort "封存檔大小為 0"
ok "封存檔存在，${bytes} bytes（$(( bytes / 1024 / 1024 / 1024 )) GiB）"

say ""
zstd -l "$ARCHIVE" | sed 's/^/    /' || abort "無法列出封存內容（zstd -l 失敗）"
say ""
pvesm list "$BACKUP_STORAGE" --content backup | grep "$(basename "$ARCHIVE")" |
  sed 's/^/    /' || abort "PVE 的備份清單裡找不到這份封存"

say ""
note "zstd -t 會把整包解壓一次並驗校驗碼 —— 比 zstd -l 強，但要花跟備份差不多的時間。"
note "不做還原，只確認讀得出來。"
if confirm "要多做一次完整解壓驗證（zstd -t）嗎？"; then
  zstd -t "$ARCHIVE" || abort "封存解壓驗證失敗；這份備份不可信"
  VERIFY="zstd -l + zstd -t（完整解壓驗證）"
  ok "完整解壓驗證通過"
else
  VERIFY="zstd -l（表頭與內容清單）"
  warn "只做了表頭層級的驗證"
fi

# ── 6 ─────────────────────────────────────────────────────────────────────
stage "記錄"
say "計算 SHA-256（$(( bytes / 1024 / 1024 / 1024 )) GiB，需要數分鐘）…"
sha=$(sha256sum "$ARCHIVE" | cut -d' ' -f1)
ok "SHA-256 ${sha}"

{
  printf '\n### 全機備份（票 02）\n\n'
  printf '| 項目 | 值 |\n| --- | --- |\n'
  printf '| 封存 | `%s` |\n' "$ARCHIVE"
  printf '| 大小 | %s bytes |\n' "$bytes"
  printf '| SHA-256 | `%s` |\n' "$sha"
  printf '| 可讀性驗證 | %s |\n' "$VERIFY"
  printf '| vzdump 記錄 | `%s` |\n' "$LOG"
  printf '\n備份不刪：留到新機器通過票 07 的驗收，且使用者明確說可以刪為止。\n'
} >> "$REPORT"
ok "已寫進票 01 的報告：${REPORT}"

finish "票 02 完成：封存在 ${ARCHIVE}"
say "下一步（不可逆的分水嶺）：PRESERVE_DIR=${HOST_DIR} ./03-destroy-vm-103.sh"
