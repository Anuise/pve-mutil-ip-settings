#!/usr/bin/env bash
#
# 票 10 — 刪除票 07 保留在 /home/mobagel 底下的來源資料。
#
# 這是整項工作最後一個不可逆動作。來源一直保留，是因為引用舊絕對路徑的設定
# 只有在服務實際跑起來後才會浮現；票 09 通過表示那個窗口已經關閉。
#
# 刪除前確認三件事：逐檔 SHA-256 比對全數相符、票 09 全數通過、票 04 列出的
# 舊路徑引用都已改指。刪除本身標記 [HUMAN ACTION]。
#
# 家目錄本身不刪；與 Demo 專案及應用狀態無關的內容不動。
#
# Blocked by 票 09。在 PVE host 上以 root 執行。

set -euo pipefail
# shellcheck source=wizard.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/wizard.sh"

TS=$(date +%Y%m%d-%H%M%S)
HOST_STATE="$(pwd)/demo-delete-${TS}"
GUEST_STATE="/root/demo-delete-${TS}"

SRC_DIR="${HOME_DIR}/${CHECKOUT_NAME}"
DST_DIR="${PLATFORM_ROOT}/${CHECKOUT_NAME}"

TOTAL_STAGES=6
banner "票 10 — 刪除保留的來源資料"

# ── 1 ─────────────────────────────────────────────────────────────────────
stage "前置檢查"
need_pve
mkdir -p "$HOST_STATE"
readback "Demo 電源狀態" "running" "$(qmstatus "$DEMO_VMID")"
qm agent "$DEMO_VMID" ping >/dev/null 2>&1 || abort "guest agent 沒有回應"
readback "Demo 的 onboot（票 09 已通過）" "1" "$(qmcfg "$DEMO_VMID" onboot)"
readback "來源仍在" "yes" \
  "$(guest_exec_or_abort "$DEMO_VMID" "test -d '${SRC_DIR}' && echo yes || echo no" \
     "無法檢查來源" | tr -d '\n')"
readback "目標仍在" "yes" \
  "$(guest_exec_or_abort "$DEMO_VMID" "test -d '${DST_DIR}' && echo yes || echo no" \
     "無法檢查目標" | tr -d '\n')"

# ── 2 ─────────────────────────────────────────────────────────────────────
stage "重新確認逐檔 SHA-256 全數相符"
say "不看票 07 留下的舊紀錄，現在重算一次 —— 刪除是不可逆的。"

# 與票 07 stage 4 同一個理由：掃全樹算 SHA-256 遠超過預設的 300 秒，而等不夠久
# 的下場是清單只寫到一半、比對卻說相符 —— 在刪除前拿到這個結論最危險。
GUEST_EXEC_TIMEOUT=3600

guest_exec_or_abort "$DEMO_VMID" "
set -e
mkdir -p '${GUEST_STATE}'
cd '${SRC_DIR}' && find . -type f -print0 | LC_ALL=C sort -z | xargs -0 -r sha256sum \
  > '${GUEST_STATE}/src-sha256.txt'
cd '${DST_DIR}' && find . -type f -print0 | LC_ALL=C sort -z | xargs -0 -r sha256sum \
  > '${GUEST_STATE}/dst-sha256.txt'
" "重算 SHA-256 失敗" >/dev/null

note "比對在 guest 內做：清單有數萬行，帶回主機只為了跑 diff 是把大量資料塞進"
note "guest agent 那條窄通道。完整清單留在 guest 的 ${GUEST_STATE}。"

DST_FILES=$(guest_exec_or_abort "$DEMO_VMID" "wc -l < '${GUEST_STATE}/dst-sha256.txt'" \
  "無法清點目標檔案數" | tr -d '\r\n')
# 先取值再 say：abort 在 say 的 command substitution 裡只殺得掉 subshell。
SRC_FILES=$(guest_exec_or_abort "$DEMO_VMID" "wc -l < '${GUEST_STATE}/src-sha256.txt'" \
  "無法清點來源檔案數" | tr -d '\r\n')
say "檔案數：來源 ${SRC_FILES}，目標 ${DST_FILES}"

n=$(guest_diff "$DEMO_VMID" "${GUEST_STATE}/src-sha256.txt" "${GUEST_STATE}/dst-sha256.txt" \
  "${GUEST_STATE}/diff-sha256.txt")
if [[ "$n" == "0" ]]; then
  ok "每一個檔案的來源與目標 SHA-256 相符"
  : > "${HOST_STATE}/diff-sha256.txt"
else
  warn "比對不符（共 ${n} 行差異，前 40 行）："
  guest_exec "$DEMO_VMID" "head -40 '${GUEST_STATE}/diff-sha256.txt'" | sed 's/^/    /' || true
  guest_exec "$DEMO_VMID" "head -200 '${GUEST_STATE}/diff-sha256.txt'" \
    > "${HOST_STATE}/diff-sha256.txt" || true
  abort "比對不符，不刪除任何東西"
fi

# ── 3 ─────────────────────────────────────────────────────────────────────
stage "確認沒有設定仍引用舊路徑"
guest_exec "$DEMO_VMID" "
{
  echo '## container bind mounts'
  docker ps -aq | while read -r c; do
    docker inspect -f '{{.Name}}{{range .Mounts}} {{.Source}}->{{.Destination}}{{end}}' \"\$c\"
  done | grep '${SRC_DIR}' || echo '(none)'
  echo
  echo '## systemd units'
  grep -rlo '${SRC_DIR}' /etc/systemd/system /lib/systemd/system 2>/dev/null || echo '(none)'
  echo
  echo '## compose 與 .conf'
  grep -rno '${SRC_DIR}[^\" :]*' --include='*.yml' --include='*.yaml' --include='*.conf' \
    '${PLATFORM_ROOT}' /etc 2>/dev/null | head -50 || echo '(none)'
} > '${GUEST_STATE}/old-path-refs.txt' 2>/dev/null
" >/dev/null || true
pull_guest_file "$DEMO_VMID" "${GUEST_STATE}/old-path-refs.txt" "${HOST_STATE}/old-path-refs.txt"

say ""
sed 's/^/    /' "${HOST_STATE}/old-path-refs.txt"
say ""
refs=$(grep -c "$SRC_DIR" "${HOST_STATE}/old-path-refs.txt" || true)
readback "仍引用 ${SRC_DIR} 的設定數" "0" "$refs"

# ── 4 ─────────────────────────────────────────────────────────────────────
stage "確認票 09 的驗收全數通過"
say "服務現況（刪除前的最後一次確認）："
health=$(guest_exec_or_abort "$EDGE_VMID" \
  "curl -kfsS --max-time 10 https://${DEMO_IP}:${DEMO_SERVICE_PORT}/healthz" \
  "Demo 的私有端點取不到；票 09 的狀態沒有維持" | tr -d '\r\n')
readback "Demo 的 /healthz" '{"status":"ok","env":"demo"}' "$health"

human_action "確認票 09 的驗收框全數勾選（含重開機恢復與 VPN client 的五項探測）。"
gate "票 09 全數通過？"

# ── 5 ─────────────────────────────────────────────────────────────────────
stage "刪除"
src_size=$(guest_exec_or_abort "$DEMO_VMID" "du -sh '${SRC_DIR}' | cut -f1" \
  "無法量測來源" | tr -d '\n')
say "只刪這一個目錄：${SRC_DIR}（${src_size}）"
say ""
say "不刪：家目錄本身，以及"
printf '      %s\n' "${KEEP_IN_HOME[@]}"
say ""
warn "這個動作不可逆，且沒有快照可退 —— 票 02 的快照早於本工作的所有變更。"
human_action "這是整項工作最後一個不可逆動作，需要你明確確認。"
gate "確定刪除 ${SRC_DIR}？"
gate "再確認一次：刪除 ${SRC_DIR}？"

guest_exec_or_abort "$DEMO_VMID" "rm -rf '${SRC_DIR}'" "刪除失敗" >/dev/null
readback "來源已刪除" "no" \
  "$(guest_exec_or_abort "$DEMO_VMID" "test -e '${SRC_DIR}' && echo yes || echo no" \
     "無法確認刪除結果" | tr -d '\n')"

readback "家目錄本身仍在" "yes" \
  "$(guest_exec_or_abort "$DEMO_VMID" \
     "test -d '${HOME_DIR}' && test -f '${HOME_DIR}/.bashrc' && echo yes || echo no" \
     "無法檢查家目錄" | tr -d '\n')"
for d in "${KEEP_IN_HOME[@]}"; do
  still=$(guest_exec_or_abort "$DEMO_VMID" \
    "test -e '${HOME_DIR}/${d}' && echo yes || echo absent" "無法檢查 ${d}" | tr -d '\n')
  ok "${d}（${still}）未被刪除"
done
readback "目標仍完整" "$DST_FILES" \
  "$(guest_exec_or_abort "$DEMO_VMID" "find '${DST_DIR}' -type f | wc -l" \
     "無法清點目標" | tr -d '\r\n')"

# ── 6 ─────────────────────────────────────────────────────────────────────
stage "刪除後兩個入口都正常"
require_free_pct "$DEMO_VMID" "$PLATFORM_ROOT"
say ""
guest_exec_or_abort "$DEMO_VMID" "df -hT '${PLATFORM_ROOT}' '${HOME_DIR}'" \
  "無法讀取用量" | sed 's/^/    /'
say ""
verify_demo_entrance
verify_uat_entrance

finish "票 10 完成：來源已刪除，兩個入口正常"
say "刪除前的比對紀錄：${HOST_STATE}"
say "整套工作到此結束。回復點與備份的保留方式見 README。"
