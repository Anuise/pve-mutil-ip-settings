#!/usr/bin/env bash
#
# 票 04 — Edge 開通 entrance port 8082，並用臨時 listener 證明整條路徑。
#
# 三條規則已經在 Edge 的 /etc/nftables.conf 裡，只是被註解掉了（「已產生、尚未
# 安裝」）。所以動作是解除註解，不是新增第四條。
#
# 依 ADR-0007 不等 CIB 上有常駐服務：規則現在裝，路徑用一個用後即拆的
# python3 -m http.server 驗完就殺掉。驗完之後 8082 會恢復成「規則在、但沒人聽」
# 的狀態，client 端測起來與未開通一樣 —— 那是預期行為。
#
# Blocked by 票 03。在 PVE host 上以 root 執行。

set -euo pipefail
# shellcheck source=wizard.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/wizard.sh"

TS=$(date +%Y%m%d-%H%M%S)
HOST_STATE="${STATE_DIR}/edge-nftables-${TS}"
EDGE_BACKUP="${EDGE_NFT_CONF}.before-${TS}"
EDGE_CANDIDATE="${EDGE_NFT_CONF}.candidate-${TS}"
PROBE_LOG="${PROBE_DIR}/server.log"
PROBE_FILE="entrance.txt"

TOTAL_STAGES=13
banner "票 04 — Edge 開通 ${EDGE_EXTERNAL_IP}:${CIB_ENTRANCE_PORT}"

# ── 1 ─────────────────────────────────────────────────────────────────────
stage "前置檢查"
need_pve
init_report
mkdir -p "$HOST_STATE"
readback "Edge（VM ${EDGE_VMID}）電源狀態" "running" "$(qmstatus "$EDGE_VMID")"
readback "CIB（VM ${CIB_VMID}）電源狀態" "running" "$(qmstatus "$CIB_VMID")"
readback "CIB 名稱" "$CIB_NAME" "$(qmcfg "$CIB_VMID" name)"
qm agent "$EDGE_VMID" ping >/dev/null 2>&1 || abort "Edge 的 guest agent 沒有回應"
qm agent "$CIB_VMID" ping >/dev/null 2>&1 || abort "CIB 的 guest agent 沒有回應"
guest_exec_or_abort "$CIB_VMID" "command -v python3" \
  "CIB 上沒有 python3，臨時 listener 起不來；改用 docker run --rm -p ${CIB_SERVICE_PORT}:80 nginx:alpine" |
  sed 's/^/    python3：/'

# ── 2 ─────────────────────────────────────────────────────────────────────
stage "CIB 沒有對外直連"
addrs=$(guest_global_addrs "$CIB_VMID")
say "    ${addrs}"
if has_lan_addr "$addrs"; then
  abort "CIB 持有 ${EXTERNAL_NET_PREFIX}.x 位址；single-entrance 設計被違反"
fi
ok "CIB 沒有任何 ${EXTERNAL_NET_PREFIX}.x 位址，只能經 entrance port 被存取"
guest_exec_or_abort "$CIB_VMID" "ss -ltn" "無法讀取 listener" | sed 's/^/    /'
note "預期只有 SSH。443 上的東西要等本票自己起，起完就拆。"

# ── 3 ─────────────────────────────────────────────────────────────────────
stage "取回 Edge 現行設定並檢查 port 衝突"
pull_guest_file "$EDGE_VMID" "$EDGE_NFT_CONF" "${HOST_STATE}/before.conf"
[[ -s "${HOST_STATE}/before.conf" ]] || abort "取回的 ${EDGE_NFT_CONF} 是空的"
readback "現行設定含 UAT 的 ${UAT_ENTRANCE_PORT} 對應" "1" \
  "$(grep -c "tcp dport ${UAT_ENTRANCE_PORT} dnat to ${UAT_IP}:443" "${HOST_STATE}/before.conf")"
ok "現行設定看起來是預期的那一份"

# ── 4 ─────────────────────────────────────────────────────────────────────
stage "產生候選設定"
say "三條規則一起處理，不拆："
say "    forward     ${CIB_IP}:${CIB_SERVICE_PORT} 限定核准的 VPN 來源"
say "    prerouting  ${CIB_ENTRANCE_PORT} 導到 ${CIB_IP}:${CIB_SERVICE_PORT}"
say "    postrouting SNAT 到 ${EDGE_PRIVATE_IP}，CIB 只會看到 Edge 為來源"
note "SNAT 讓 CIB 不需要信任 client 提供的 proxy header。"
say ""

rc=0
nft_uncomment_entrance_rules "$CIB_ENTRANCE_PORT" "$CIB_IP" "$CIB_SERVICE_PORT" \
  < "${HOST_STATE}/before.conf" > "${HOST_STATE}/candidate.conf" || rc=$?
case "$rc" in
  0) ok "三條被註解的規則已解除註解" ;;
  2) abort "port ${CIB_ENTRANCE_PORT} 已經有未被註解的 DNAT 規則；不覆蓋既有配置" ;;
  1)
    warn "設定檔裡找不到那三條被註解的規則（設定檔換過？）"
    note "退回 nft_add_entrance_rules 產生它們。"
    rc=0
    nft_add_entrance_rules "$CIB_ENTRANCE_PORT" "$CIB_IP" "$CIB_SERVICE_PORT" \
      < "${HOST_STATE}/before.conf" > "${HOST_STATE}/candidate.conf" || rc=$?
    case "$rc" in
      0) ok "三條規則已新增" ;;
      1) abort "找不到可插入的錨點；請人工檢查 ${HOST_STATE}/before.conf" ;;
      2) abort "port ${CIB_ENTRANCE_PORT} 已被 DNAT 佔用；不覆蓋既有配置" ;;
      *) abort "產生候選設定失敗（rc=${rc}）" ;;
    esac ;;
  *) abort "產生候選設定失敗（rc=${rc}）" ;;
esac

say ""
diff -u "${HOST_STATE}/before.conf" "${HOST_STATE}/candidate.conf" | sed 's/^/    /' || true
say ""
readback "生效的 DNAT 規則數（前 +1）" \
  "$(( $(grep -cE '^[[:space:]]*iifname.* dnat to ' "${HOST_STATE}/before.conf") + 1 ))" \
  "$(grep -cE '^[[:space:]]*iifname.* dnat to ' "${HOST_STATE}/candidate.conf")"
readback "預設拒絕政策未放寬" \
  "$(grep -c 'policy drop;' "${HOST_STATE}/before.conf")" \
  "$(grep -c 'policy drop;' "${HOST_STATE}/candidate.conf")"
gate "這個差異正確？"

# ── 5 ─────────────────────────────────────────────────────────────────────
stage "安裝前驗證候選設定"
note "載不進去的設定會同時中斷所有服務，不只是新加的這一個。"
guest_put_file "$EDGE_VMID" "$EDGE_CANDIDATE" 0644 < "${HOST_STATE}/candidate.conf"
guest_exec_or_abort "$EDGE_VMID" "nft -c -f '${EDGE_CANDIDATE}'" \
  "候選設定沒有通過 nft -c -f；現行規則未被改動" >/dev/null
ok "候選設定通過 nft -c -f，現行規則此刻仍未改動"

# ── 6 ─────────────────────────────────────────────────────────────────────
stage "備份現行設定並安裝"
note "反向動作：nft -c -f '${EDGE_BACKUP}' 驗證後再還原它並 reload。不驗證就不還原。"
gate "備份並安裝候選設定？"
guest_exec_or_abort "$EDGE_VMID" "cp -a '${EDGE_NFT_CONF}' '${EDGE_BACKUP}'" \
  "備份現行設定失敗" >/dev/null
ok "已備份為 ${EDGE_BACKUP}"
guest_exec_or_abort "$EDGE_VMID" \
  "install -o root -g root -m 0755 '${EDGE_CANDIDATE}' '${EDGE_NFT_CONF}' &&
   rm -f '${EDGE_CANDIDATE}' &&
   systemctl reload nftables" \
  "安裝或 reload 失敗；以 ${EDGE_BACKUP} 還原" >/dev/null
readback "nftables 服務" "active" \
  "$(guest_exec "$EDGE_VMID" "systemctl is-active nftables" | tr -d '\n')"

# ── 7 ─────────────────────────────────────────────────────────────────────
stage "讀回執行中的規則"
guest_exec_or_abort "$EDGE_VMID" "nft list ruleset" "無法讀取執行中的規則" \
  > "${HOST_STATE}/running.txt"
readback "執行中的 DNAT" "1" \
  "$(grep -c "dport ${CIB_ENTRANCE_PORT} dnat to ${CIB_IP}:${CIB_SERVICE_PORT}" \
     "${HOST_STATE}/running.txt")"
readback "執行中的 SNAT" "1" \
  "$(grep -c "daddr ${CIB_IP} tcp dport ${CIB_SERVICE_PORT} snat to ${EDGE_PRIVATE_IP}" \
     "${HOST_STATE}/running.txt")"
readback "執行中的 forward 放行" "1" \
  "$(grep -c "daddr ${CIB_IP} tcp dport ${CIB_SERVICE_PORT} ct status dnat accept" \
     "${HOST_STATE}/running.txt")"
readback "UAT 的 ${UAT_ENTRANCE_PORT} 仍在" "1" \
  "$(grep -c "dport ${UAT_ENTRANCE_PORT} dnat to ${UAT_IP}:443" "${HOST_STATE}/running.txt")"
# 每一條 dnat 都必須是「單一 port 到單一 IP:port」。數目不等就代表有 range
# 或 catch-all 混進來。
readback "沒有 port range 或 catch-all 的 DNAT" \
  "$(grep -c 'dnat to' "${HOST_STATE}/running.txt")" \
  "$(grep -cE 'dport [0-9]+ dnat to [0-9.]+:[0-9]+$' "${HOST_STATE}/running.txt")"
readback "管理端點未出現在任何規則中" "0" \
  "$(grep -c '8006' "${HOST_STATE}/running.txt" || true)"
readback "forward 的 log/drop 規則仍在" "1" \
  "$(grep -c 'edge-forward-drop' "${HOST_STATE}/running.txt")"

# ── 8 ─────────────────────────────────────────────────────────────────────
stage "起臨時 listener"
note "用後即拆（ADR-0007）。timeout ${PROBE_TTL} 秒，就算腳本中途死掉它自己也會結束。"
guest_exec_or_abort "$CIB_VMID" "
  mkdir -p '${PROBE_DIR}' &&
  printf '%s\n' '${PROBE_TEXT}' > '${PROBE_DIR}/index.html' &&
  printf '%s\n' '${PROBE_TEXT}' > '${PROBE_DIR}/${PROBE_FILE}' &&
  cd '${PROBE_DIR}' &&
  setsid sh -c 'exec timeout ${PROBE_TTL} python3 -m http.server ${CIB_SERVICE_PORT} --bind 0.0.0.0' \
    > '${PROBE_LOG}' 2>&1 < /dev/null &
  sleep 3; :" "無法在 CIB 上啟動臨時 listener" >/dev/null

listeners=$(guest_exec_or_abort "$CIB_VMID" "ss -ltn" "無法讀取 listener")
printf '%s\n' "$listeners" | sed 's/^/    /'
if ! printf '%s\n' "$listeners" | ss_reachable_listener "$CIB_SERVICE_PORT"; then
  guest_exec "$CIB_VMID" "cat '${PROBE_LOG}'" | sed 's/^/    /' || true
  abort "${CIB_SERVICE_PORT} 上沒有綁在非 loopback 位址的 listener；DNAT 不會有人回答"
fi
ok "${CIB_SERVICE_PORT} 上有綁在非 loopback 位址的 listener"

# ── 9 ─────────────────────────────────────────────────────────────────────
stage "私有段：從 Edge 內部打 CIB"
body=$(guest_exec_or_abort "$EDGE_VMID" \
  "curl -sS --max-time 10 http://${CIB_IP}:${CIB_SERVICE_PORT}/" \
  "Edge 打不到 ${CIB_IP}:${CIB_SERVICE_PORT}；先修私有段，DNAT 的問題還輪不到" |
  tr -d '\r\n')
readback "Edge 內部取得的內容" "$PROBE_TEXT" "$body"
ok "私有段通：規則之外的那一段沒有問題"

# ── 10 ────────────────────────────────────────────────────────────────────
stage "從核准的 VPN client 驗收"
say "這是本工作的主要 seam：一個已連上核准 VPN 的黑箱 client。"
say ""
human_action "從已連上核准 FortiClient VPN 的 Windows client 依序執行："
say ""
say "    # 來源位址（記錄用）"
say "    ipconfig | Select-String IPv4"
say ""
say "    # 1 CIB 的入口（路徑刻意與上一步不同，log 才分得出是哪一次請求）"
say "    curl.exe -sS http://${EDGE_EXTERNAL_IP}:${CIB_ENTRANCE_PORT}/${PROBE_FILE}"
say ""
say "    # 2 UAT 的入口不受影響"
say "    curl.exe -kfsS https://${EDGE_EXTERNAL_IP}:${UAT_ENTRANCE_PORT}/healthz"
say ""
say "    # 3 未配置的 port 必須 fail closed"
say "    Test-NetConnection ${EDGE_EXTERNAL_IP} -Port ${UNALLOCATED_PORT}"
say ""
say "    # 4 私有位址不可直達"
say "    Test-NetConnection ${CIB_IP} -Port ${CIB_SERVICE_PORT}"
say ""
say "預期：1 回「${PROBE_TEXT}」；2 回 UAT 的 healthz；3 與 4 的 TcpTestSucceeded=False。"
gate "1 拿到那行字串，2 正常，3 與 4 都失敗？"

# ── 11 ────────────────────────────────────────────────────────────────────
stage "SNAT 生效的證據"
note "上一步的探測 1 會出現在 listener 的 log 裡，來源必須是 ${EDGE_PRIVATE_IP}。"
note "Edge 內部那一次打的是 /，client 打的是 /${PROBE_FILE} —— 靠路徑分辨，"
note "不然兩者的來源都是 ${EDGE_PRIVATE_IP}，證據就沒有分辨力。"
guest_exec_or_abort "$CIB_VMID" "cat '${PROBE_LOG}'" "無法讀取 listener 的 log" \
  > "${HOST_STATE}/probe-access.txt"
sed 's/^/    /' "${HOST_STATE}/probe-access.txt"
say ""
via=$(grep -c "^${EDGE_PRIVATE_IP} .*GET /${PROBE_FILE}" "${HOST_STATE}/probe-access.txt" || true)
[[ "$via" -gt 0 ]] ||
  abort "log 裡沒有以 ${EDGE_PRIVATE_IP} 為來源、路徑為 /${PROBE_FILE} 的請求；SNAT 未生效，或上一步的探測 1 沒有執行"
ok "CIB 看到的來源是 ${EDGE_PRIVATE_IP}（${via} 筆），不需要信任 client 的 proxy header"

# ── 12 ────────────────────────────────────────────────────────────────────
stage "拆掉臨時 listener"
guest_exec_or_abort "$CIB_VMID" "
  pkill -f 'http.server ${CIB_SERVICE_PORT}' || true
  sleep 2
  rm -rf '${PROBE_DIR}'
  :" "無法停止臨時 listener" >/dev/null
listeners=$(guest_exec_or_abort "$CIB_VMID" "ss -ltn" "無法讀取 listener")
if printf '%s\n' "$listeners" | ss_reachable_listener "$CIB_SERVICE_PORT"; then
  printf '%s\n' "$listeners" | sed 's/^/    /'
  abort "${CIB_SERVICE_PORT} 上還有 listener；臨時 listener 沒有拆乾淨"
fi
ok "${CIB_SERVICE_PORT} 上沒有殘留的 listener"
readback "探測目錄已刪除（test -e 的結束碼）" "1" \
  "$(guest_exec "$CIB_VMID" "test -e '${PROBE_DIR}'; printf %s \$?" | tr -d '\r\n')"

# ── 13 ────────────────────────────────────────────────────────────────────
stage "收尾"
verify_uat_entrance
say ""
warn "現在 ${CIB_ENTRANCE_PORT} 的規則在，但 CIB 上沒有人在聽 ${CIB_SERVICE_PORT}。"
say "  因此 Test-NetConnection ${EDGE_EXTERNAL_IP} -Port ${CIB_ENTRANCE_PORT} 會失敗 ——"
say "  DNAT 送到沒人聽的 port，guest 回 RST，client 端看起來與未開通一模一樣。"
say "  這是預期行為，不是故障（ADR-0007）。要重新確認入口，就再起一次臨時 listener。"
report_section "開通 ${CIB_ENTRANCE_PORT}（票 04）"
{
  printf '| 項目 | 值 |\n| --- | --- |\n'
  printf '| DNAT | `%s:%s 到 %s:%s` |\n' \
    "$EDGE_EXTERNAL_IP" "$CIB_ENTRANCE_PORT" "$CIB_IP" "$CIB_SERVICE_PORT"
  printf '| Edge 設定備份 | `%s` |\n' "$EDGE_BACKUP"
  printf '| 前後設定與探測紀錄 | `%s` |\n' "$HOST_STATE"
  printf '| SNAT 證據 | log 中 %s 筆來自 `%s` 的 `/%s` 請求 |\n' \
    "$via" "$EDGE_PRIVATE_IP" "$PROBE_FILE"
  printf '| 臨時 listener | 已停止，`%s` 已刪除 |\n' "$PROBE_DIR"
  printf '| 目前 %s 上的 listener | 無，%s 因此 fail closed（屬預期） |\n' \
    "$CIB_SERVICE_PORT" "$CIB_ENTRANCE_PORT"
} >> "$REPORT"
say ""
say "repo 要同步的那一份（票 05）："
say ""
say "    scp root@${PVE_HOST_IP}:${HOST_STATE}/candidate.conf /tmp/edge.conf"
say "    diff -u .scratch/single-ip-multi-site-network/nftables.edge.conf /tmp/edge.conf"
say ""

finish "票 04 完成：${EDGE_EXTERNAL_IP}:${CIB_ENTRANCE_PORT} 已開通"
say "Edge 設定備份：${EDGE_BACKUP}"
say "本次紀錄：${HOST_STATE}"
say "onboot 仍為 0。要開機自啟請自行 qm set ${CIB_VMID} --onboot 1。"
say "下一步：票 05 是 repo 與文件收尾，交給 agent 做，不在 PVE 上執行。"
