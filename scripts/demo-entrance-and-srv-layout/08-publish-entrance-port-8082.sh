#!/usr/bin/env bash
#
# 票 08 — Edge 開通 entrance port 8082。
#
# 依既有慣例三條規則一起加，不拆：forward 放行、prerouting DNAT、postrouting
# SNAT。不建立 port range 或 catch-all，input 與 forward 的預設拒絕政策不放寬。
#
# 安裝前先以 nft -c -f 驗證候選設定，並備份現行設定 —— 一份載不進去的設定會
# 同時中斷所有服務，而不只是新加的那一個。
#
# 「回應 Demo」指的是票 11 那個 nginx 端點的 TLS 回應且可與 UAT 區分，
# 不是「Demo 應用可用」——應用本體部署不在本 spec，見 ADR-0003。
#
# Blocked by 票 11。在 PVE host 上以 root 執行。

set -euo pipefail
# shellcheck source=wizard.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/wizard.sh"

TS=$(date +%Y%m%d-%H%M%S)
HOST_STATE="$(pwd)/edge-nftables-${TS}"
EDGE_BACKUP="${EDGE_NFT_CONF}.before-${TS}"
EDGE_CANDIDATE="${EDGE_NFT_CONF}.candidate-${TS}"

TOTAL_STAGES=11
banner "票 08 — Edge 開通 entrance port ${DEMO_ENTRANCE_PORT}"

# ── 1 ─────────────────────────────────────────────────────────────────────
stage "前置檢查"
need_pve
readback "Edge 電源狀態" "running" "$(qmstatus "$EDGE_VMID")"
readback "Demo 電源狀態" "running" "$(qmstatus "$DEMO_VMID")"
qm agent "$EDGE_VMID" ping >/dev/null 2>&1 || abort "Edge 的 guest agent 沒有回應"

health=$(guest_exec_or_abort "$EDGE_VMID" \
  "curl -kfsS --max-time 10 https://${DEMO_IP}:${DEMO_SERVICE_PORT}/healthz" \
  "DNAT 的目的地 ${DEMO_IP}:${DEMO_SERVICE_PORT} 沒有人在聽；票 11 未完成" | tr -d '\r\n')
readback "DNAT 目的地的回應（票 11）" '{"status":"ok","env":"demo"}' "$health"
ok "先證明私有端點健康，再改任何 DNAT 規則"

# ── 2 ─────────────────────────────────────────────────────────────────────
stage "Demo 沒有對外直連的 listener"
say "Demo 只能經 entrance port 被存取。"

addrs=$(guest_global_addrs "$DEMO_VMID")
say "    ${addrs}"
[[ "$addrs" != *"=10.1.2."* ]] || abort "Demo 仍持有 10.1.2.x 位址；single-entrance 設計被違反"
ok "Demo 沒有任何 10.1.2.x 位址"

say ""
say "Demo 目前的 listener："
guest_exec_or_abort "$DEMO_VMID" "ss -ltn" "無法讀取 listener" | sed 's/^/    /'
say ""
note "預期只有票 11 的 443（以及 SSH）。實體 bridge 上的舊 80/443 直連在票 02 就已消失。"
gate "上面沒有多餘的對外 listener？"

# ── 3 ─────────────────────────────────────────────────────────────────────
stage "取回 Edge 現行設定並檢查 port 衝突"
mkdir -p "$HOST_STATE"
pull_guest_file "$EDGE_VMID" "$EDGE_NFT_CONF" "${HOST_STATE}/before.conf"
[[ -s "${HOST_STATE}/before.conf" ]] || abort "取回的 ${EDGE_NFT_CONF} 是空的"

readback "現行設定含 UAT 的 ${UAT_ENTRANCE_PORT} 對應" "1" \
  "$(grep -c "tcp dport ${UAT_ENTRANCE_PORT} dnat to ${UAT_IP}:443" "${HOST_STATE}/before.conf")"
ok "現行設定看起來是預期的那一份"

# ── 4 ─────────────────────────────────────────────────────────────────────
stage "產生候選設定"
say "三條規則一起加，各插在同類規則的最後一條之後："
say "    forward     ${DEMO_IP}:${DEMO_SERVICE_PORT} 限定核准的 VPN 來源"
say "    prerouting  ${DEMO_ENTRANCE_PORT} → ${DEMO_IP}:${DEMO_SERVICE_PORT}"
say "    postrouting SNAT 到 ${EDGE_PRIVATE_IP}，Demo 只會看到 Edge 為來源"
note "SNAT 讓 Demo 不需要信任 client 提供的 proxy header。"

rc=0
nft_add_entrance_rules "$DEMO_ENTRANCE_PORT" "$DEMO_IP" "$DEMO_SERVICE_PORT" \
  < "${HOST_STATE}/before.conf" > "${HOST_STATE}/candidate.conf" || rc=$?
case "$rc" in
  0) ;;
  1) abort "現行設定裡找不到可插入的錨點；請人工檢查 ${HOST_STATE}/before.conf" ;;
  2) abort "port ${DEMO_ENTRANCE_PORT} 已經有 DNAT 規則；不覆蓋、不取代既有配置" ;;
  *) abort "產生候選設定失敗（rc=${rc}）" ;;
esac

say ""
diff -u "${HOST_STATE}/before.conf" "${HOST_STATE}/candidate.conf" | sed 's/^/    /' || true
say ""
readback "新增的規則數" "3" \
  "$(diff "${HOST_STATE}/before.conf" "${HOST_STATE}/candidate.conf" | grep -c '^>')"
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
  "$(grep -c "dport ${DEMO_ENTRANCE_PORT} dnat to ${DEMO_IP}:${DEMO_SERVICE_PORT}" \
     "${HOST_STATE}/running.txt")"
readback "執行中的 SNAT" "1" \
  "$(grep -c "daddr ${DEMO_IP} tcp dport ${DEMO_SERVICE_PORT} snat to ${EDGE_PRIVATE_IP}" \
     "${HOST_STATE}/running.txt")"
readback "執行中的 forward 放行" "1" \
  "$(grep -c "daddr ${DEMO_IP} tcp dport ${DEMO_SERVICE_PORT} ct status dnat accept" \
     "${HOST_STATE}/running.txt")"
readback "UAT 的 ${UAT_ENTRANCE_PORT} 仍在" "1" \
  "$(grep -c "dport ${UAT_ENTRANCE_PORT} dnat to ${UAT_IP}:443" "${HOST_STATE}/running.txt")"
# 每一條 dnat 都必須是「單一 port → 單一 IP:port」。數目不等就代表有 range
# 或 catch-all 混進來。
readback "沒有 port range 或 catch-all 的 DNAT" \
  "$(grep -c 'dnat to' "${HOST_STATE}/running.txt")" \
  "$(grep -cE 'dport [0-9]+ dnat to [0-9.]+:[0-9]+$' "${HOST_STATE}/running.txt")"
readback "管理端點未出現在任何規則中" "0" \
  "$(grep -c '8006' "${HOST_STATE}/running.txt" || true)"

# ── 8 ─────────────────────────────────────────────────────────────────────
stage "從核准的 VPN client 驗收"
say "這是本工作的主要 seam：一個已連上核准 VPN 的黑箱 client。"
note "每次探測記錄來源位址、目的與結果，且由當初建立經驗性 gate 的同一個 client 執行。"
say ""
human_action "從已連上核准 FortiClient VPN 的 Windows client 依序執行："
say ""
say "    # 來源位址（記錄用）"
say "    ipconfig | Select-String IPv4"
say ""
say "    # 1 Demo 的入口"
say "    Test-NetConnection ${EDGE_EXTERNAL_IP} -Port ${DEMO_ENTRANCE_PORT}"
say "    curl.exe -kfsS https://${EDGE_EXTERNAL_IP}:${DEMO_ENTRANCE_PORT}/healthz"
say ""
say "    # 2 UAT 的入口不受影響"
say "    curl.exe -kfsS https://${EDGE_EXTERNAL_IP}:${UAT_ENTRANCE_PORT}/healthz"
say ""
say "    # 3 未配置的 port 必須 fail closed"
say "    Test-NetConnection ${EDGE_EXTERNAL_IP} -Port ${UNALLOCATED_PORT}"
say ""
say "    # 4 私有位址不可直達"
say "    Test-NetConnection ${DEMO_IP} -Port ${DEMO_SERVICE_PORT}"
say ""
say "    # 5 根路徑（/healthz 的 access_log 是關的，SNAT 的證據要靠這一次）"
say "    curl.exe -kfsS https://${EDGE_EXTERNAL_IP}:${DEMO_ENTRANCE_PORT}/"
say ""
say '預期：1 回 {"status":"ok","env":"demo"}；2 回 {"status":"ok"}；'
say "     3 與 4 的 TcpTestSucceeded=False；5 回 Demo entrance 的頁面。"
gate "1 與 2 的回應可區分，3 與 4 都失敗，且 5 有回應？"

say ""
say "HTTP 與 WebSocket 的透明性："
note "Edge 做的是 L4 DNAT，TLS 在 Demo 的 nginx 才終結 —— Edge 讀不到也改不了"
note "TCP 之上的任何東西。所以只要憑證是 Demo 自己的，就沒有中間人在解析 HTTP，"
note "WebSocket 的 Upgrade 交握自然透明。這是可檢查的性質，不是宣稱。"
say ""
human_action "在瀏覽器開 https://${EDGE_EXTERNAL_IP}:${DEMO_ENTRANCE_PORT}/ 並檢視憑證。"
say ""
say "預期：憑證是 Demo 自己的自簽憑證，與 ${UAT_ENTRANCE_PORT} 的那一張不同。"
gate "${DEMO_ENTRANCE_PORT} 的憑證是 Demo 的，且與 ${UAT_ENTRANCE_PORT} 的不同？"

human_action "中斷 VPN 後重測 ${DEMO_ENTRANCE_PORT} 與 ${UAT_ENTRANCE_PORT}，再接回。"
say ""
say "    Test-NetConnection ${EDGE_EXTERNAL_IP} -Port ${DEMO_ENTRANCE_PORT}"
say "    Test-NetConnection ${EDGE_EXTERNAL_IP} -Port ${UAT_ENTRANCE_PORT}"
say ""
gate "未連 VPN 時兩個 port 都不可達？"
note "這只證明當下可達性，不揭露 FortiGate 的 policy 範圍、client pool 或 user group。"

# ── 9 ─────────────────────────────────────────────────────────────────────
stage "Demo 觀察到的連線來源是 Edge 的私有位址"
say "上一步的探測 5（根路徑）會出現在 Demo 的 nginx access log 裡。"
note "這是驗證 SNAT 生效，而不是假設它生效。"
note "/healthz 的 access_log 是關的，Test-NetConnection 又只是 TCP，所以能作證的"
note "只有那一次根路徑請求。"

guest_exec_or_abort "$DEMO_VMID" "docker logs --tail 20 '${DEMO_PROXY}' 2>&1" \
  "無法讀取 Demo 的 nginx log" > "${HOST_STATE}/demo-access.txt"
sed 's/^/    /' "${HOST_STATE}/demo-access.txt"
say ""
from_edge=$(grep -c "^${EDGE_PRIVATE_IP} " "${HOST_STATE}/demo-access.txt" || true)
[[ "$from_edge" -gt 0 ]] ||
  abort "log 中沒有以 ${EDGE_PRIVATE_IP} 為來源的請求；SNAT 未生效，或上一步的探測 5 沒有執行"
ok "Demo 看到的來源是 ${EDGE_PRIVATE_IP}（${from_edge} 筆），不需要信任 client 的 proxy header"

# ── 10 ────────────────────────────────────────────────────────────────────
stage "管理端點未被改動或代理"
human_action "從同一個 VPN client 開啟 https://${MGMT_ENDPOINT}"
say ""
say "預期：與本次變更前完全相同，且不經過 Edge。"
gate "管理端點行為不變？"

# ── 11 ────────────────────────────────────────────────────────────────────
stage "log 涵蓋與 repo 一致性"
readback "forward 的 log/drop 規則仍在" "1" \
  "$(grep -c 'edge-forward-drop' "${HOST_STATE}/running.txt")"
say ""
say "最近的轉送失敗紀錄（沒有就是沒有失敗，屬正常）："
guest_exec "$EDGE_VMID" "journalctl -k -g edge-forward-drop -n 5 --no-pager 2>&1 | tail -5" |
  sed 's/^/    /' || true

say ""
say "repo 的 ruleset、runbook 配置表與 port map 已在同一次變更中更新："
say "    .scratch/single-ip-multi-site-network/nftables.edge.conf"
say "    docs/runbooks/single-ip-multi-site.md"
say ""
say "比對執行狀態與 repo 追蹤的那一份："
say ""
say "    scp root@${PVE_HOST_IP}:${HOST_STATE}/candidate.conf /tmp/edge.conf"
say "    diff -u .scratch/single-ip-multi-site-network/nftables.edge.conf /tmp/edge.conf"
say ""
gate "repo 與執行狀態一致？"

finish "票 08 完成：${EDGE_EXTERNAL_IP}:${DEMO_ENTRANCE_PORT} 已開通"
say "現行設定的備份：${EDGE_BACKUP}（Edge 上）"
say "本次的前後設定與探測紀錄：${HOST_STATE}"
say "開機自啟仍為關閉，等票 09 驗收通過再開。"
say "下一步：./09-reboot-acceptance.sh"
