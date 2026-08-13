#!/usr/bin/env bash
#
# 票 09 — 重開機驗收與開機自啟。
#
# 證明整套設定能在重新開機後自行恢復。通過之後才開啟 Demo 的開機自啟 ——
# 提早開啟等於讓 hypervisor 重開機把一個未驗證的設定帶回來。
#
# 兩個 seam 整套重跑：已連上核准 VPN 的黑箱 client，以及 guest 內部的儲存位置
# 與資料完整性。每次探測記錄來源位址、目的與結果。
#
# Blocked by 票 08。在核准的時段、在 PVE host 上以 root 執行。

set -euo pipefail
# shellcheck source=wizard.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/wizard.sh"

TS=$(date +%Y%m%d-%H%M%S)
HOST_STATE="$(pwd)/demo-acceptance-${TS}"
PROBES="${HOST_STATE}/probes.txt"

# probe 來源 目的 結果 — 每次探測都留下紀錄，不只留下結論。
probe() { printf '%s|%s|%s\n' "$1" "$2" "$3" >> "$PROBES"; }

TOTAL_STAGES=9
banner "票 09 — 重開機驗收與開機自啟"

# ── 1 ─────────────────────────────────────────────────────────────────────
stage "前置檢查"
need_pve
mkdir -p "$HOST_STATE"
: > "$PROBES"

readback "Demo 電源狀態" "running" "$(qmstatus "$DEMO_VMID")"
readback "Edge 電源狀態" "running" "$(qmstatus "$EDGE_VMID")"
onboot=$(qmcfg "$DEMO_VMID" onboot)
[[ -z "$onboot" || "$onboot" == "0" ]] || abort "Demo 的 onboot 已經開著；本票的前提是它還沒開"
ok "Demo 的開機自啟目前為關閉（本票通過後才開）"

warn "本票會重新開機 Demo 與 Edge。重開 Edge 期間 8081 與 8082 都會中斷。"
human_action "確認現在是核准的時段。"
gate "現在可以重新開機嗎？"

# ── 2 ─────────────────────────────────────────────────────────────────────
stage "重開機前的基準"
before_health=$(guest_exec_or_abort "$EDGE_VMID" \
  "curl -kfsS --max-time 10 https://${DEMO_IP}:${DEMO_SERVICE_PORT}/healthz" \
  "重開機前 Demo 的私有端點就取不到" | tr -d '\r\n')
readback "重開機前 Demo 的 /healthz" '{"status":"ok","env":"demo"}' "$before_health"
probe "$EDGE_PRIVATE_IP" "${DEMO_IP}:${DEMO_SERVICE_PORT}/healthz" "ok（重開機前）"

guest_exec_or_abort "$EDGE_VMID" "nft list ruleset" "無法讀取 Edge 規則" \
  > "${HOST_STATE}/rules-before.txt"
ok "已記錄 Edge 現行規則（$(wc -l < "${HOST_STATE}/rules-before.txt") 行）"

# ── 3 ─────────────────────────────────────────────────────────────────────
stage "重新開機 Demo"
reboot_and_wait "$DEMO_VMID"

# ── 4 ─────────────────────────────────────────────────────────────────────
stage "重新開機 Edge"
reboot_and_wait "$EDGE_VMID"

# ── 5 ─────────────────────────────────────────────────────────────────────
stage "Edge 的防火牆政策自動恢復"
readback "nftables 服務" "active" \
  "$(guest_exec "$EDGE_VMID" "systemctl is-active nftables" | tr -d '\n')"
readback "ip_forward" "1" \
  "$(guest_exec_or_abort "$EDGE_VMID" "cat /proc/sys/net/ipv4/ip_forward" \
     "無法讀取 ip_forward" | tr -d '\n')"

guest_exec_or_abort "$EDGE_VMID" "nft list ruleset" "無法讀取 Edge 規則" \
  > "${HOST_STATE}/rules-after.txt"
if diff -u "${HOST_STATE}/rules-before.txt" "${HOST_STATE}/rules-after.txt" \
     > "${HOST_STATE}/rules-diff.txt"; then
  ok "重開機後的規則與重開機前完全相同"
else
  warn "規則有差異（counter 歸零屬正常，規則本身不該變）："
  sed 's/^/    /' "${HOST_STATE}/rules-diff.txt"
  gate "差異只是 counter 而非規則本身？"
fi
readback "${DEMO_ENTRANCE_PORT} 的 DNAT 仍在" "1" \
  "$(grep -c "dport ${DEMO_ENTRANCE_PORT} dnat to ${DEMO_IP}:${DEMO_SERVICE_PORT}" \
     "${HOST_STATE}/rules-after.txt")"
readback "${UAT_ENTRANCE_PORT} 的 DNAT 仍在" "1" \
  "$(grep -c "dport ${UAT_ENTRANCE_PORT} dnat to ${UAT_IP}:443" "${HOST_STATE}/rules-after.txt")"

# ── 6 ─────────────────────────────────────────────────────────────────────
stage "Demo 的掛載、data-root 與容器自動恢復"
readback "${PLATFORM_ROOT} 自動掛回" "/dev/mapper/vg_data-lv_docker" \
  "$(guest_exec_or_abort "$DEMO_VMID" "findmnt -rno SOURCE '${PLATFORM_ROOT}'" \
     "${PLATFORM_ROOT} 沒有掛回" | tr -d '\n')"
readback "/srv 仍掛載" "/dev/mapper/vg_data-lv_srv" \
  "$(guest_exec_or_abort "$DEMO_VMID" "findmnt -rno SOURCE /srv" "/srv 沒有掛回" | tr -d '\n')"
readback "Docker 的 data-root" "${PLATFORM_ROOT}/docker" \
  "$(guest_exec_or_abort "$DEMO_VMID" "docker info --format '{{.DockerRootDir}}'" \
     "無法讀取 data-root" | tr -d '\n')"
readback "checkout 仍在新位置" "yes" \
  "$(guest_exec_or_abort "$DEMO_VMID" \
     "test -d '${PLATFORM_ROOT}/${CHECKOUT_NAME}' && echo yes || echo no" \
     "無法檢查 checkout" | tr -d '\n')"

for c in "${DEMO_STACK_CONTAINERS[@]}"; do
  readback "${c} 無需人工介入即恢復" "running" "$(wait_container_running "$DEMO_VMID" "$c")"
done

require_free_pct "$DEMO_VMID" "$PLATFORM_ROOT"

health=$(guest_exec_or_abort "$EDGE_VMID" \
  "curl -kfsS --max-time 10 https://${DEMO_IP}:${DEMO_SERVICE_PORT}/healthz" \
  "重開機後 Edge 取不到 Demo 的 /healthz" | tr -d '\r\n')
readback "重開機後 Demo 的 /healthz" '{"status":"ok","env":"demo"}' "$health"
probe "$EDGE_PRIVATE_IP" "${DEMO_IP}:${DEMO_SERVICE_PORT}/healthz" "ok（重開機後）"

# ── 7 ─────────────────────────────────────────────────────────────────────
stage "VPN client seam 全套重測"
say "由當初建立經驗性 gate 的同一個 client 執行。"
say ""
human_action "從已連上核准 FortiClient VPN 的 Windows client 執行："
say ""
say "    ipconfig | Select-String IPv4"
say "    curl.exe -kfsS https://${EDGE_EXTERNAL_IP}:${DEMO_ENTRANCE_PORT}/healthz"
say "    curl.exe -kfsS https://${EDGE_EXTERNAL_IP}:${UAT_ENTRANCE_PORT}/healthz"
say "    Test-NetConnection ${EDGE_EXTERNAL_IP} -Port ${UNALLOCATED_PORT}"
say "    Test-NetConnection ${DEMO_IP} -Port ${DEMO_SERVICE_PORT}"
say ""
printf '  %s來源位址（記入探測紀錄）：%s ' "$YELLOW" "$RESET"
read -r client_ip || true
[[ -n "$client_ip" ]] || abort "探測紀錄需要來源位址"

gate "${DEMO_ENTRANCE_PORT} 回 Demo，且與 ${UAT_ENTRANCE_PORT} 的回應可區分？"
probe "$client_ip" "${EDGE_EXTERNAL_IP}:${DEMO_ENTRANCE_PORT}/healthz" "ok，回應為 Demo"
probe "$client_ip" "${EDGE_EXTERNAL_IP}:${UAT_ENTRANCE_PORT}/healthz" "ok，回應為 UAT"

gate "未配置的 ${UNALLOCATED_PORT} fail closed，且沒有落到任何環境？"
probe "$client_ip" "${EDGE_EXTERNAL_IP}:${UNALLOCATED_PORT}" "拒絕（fail closed）"

gate "私有位址 ${DEMO_IP} 無法直接連上？"
probe "$client_ip" "${DEMO_IP}:${DEMO_SERVICE_PORT}" "不可達"

human_action "中斷 VPN 後重測兩個 port，再接回。"
gate "未連 VPN 時 ${DEMO_ENTRANCE_PORT} 與 ${UAT_ENTRANCE_PORT} 皆不可達？"
probe "未連 VPN" "${EDGE_EXTERNAL_IP}:${DEMO_ENTRANCE_PORT}、:${UAT_ENTRANCE_PORT}" "皆不可達"

human_action "開啟 https://${MGMT_ENDPOINT} 確認管理端點行為不變。"
gate "管理端點不變且未被代理？"
probe "$client_ip" "https://${MGMT_ENDPOINT}" "不變、未經 Edge"

# ── 8 ─────────────────────────────────────────────────────────────────────
stage "Demo 的出站與管理端點隔離"
say "出站：Demo 經 Edge 的 outbound NAT 連核准的更新來源。"
if guest_exec "$DEMO_VMID" \
     "curl -sS --max-time 20 -o /dev/null -w '%{http_code}' https://archive.ubuntu.com/ubuntu/" \
     > "${HOST_STATE}/outbound.txt" 2>&1; then
  ok "出站可達（HTTP $(tr -d '\n' < "${HOST_STATE}/outbound.txt")）"
  probe "$DEMO_IP" "https://archive.ubuntu.com/ubuntu/" "可達（經 Edge outbound NAT）"
else
  warn "出站測試失敗：$(sed 's/^/    /' "${HOST_STATE}/outbound.txt")"
  human_action "確認 Edge 的 outbound 規則與上游是否允許此目的地。"
  gate "出站行為符合預期？"
fi

say ""
say "隔離：Demo 不得主動連到管理端點。"
if guest_exec "$DEMO_VMID" "curl -ksS --max-time 8 -o /dev/null https://${MGMT_ENDPOINT}/" \
     >/dev/null 2>&1; then
  abort "Demo 連得到管理端點 ${MGMT_ENDPOINT}；private guest 不該能探測基礎設施"
fi
ok "Demo 無法主動連到 ${MGMT_ENDPOINT}"
probe "$DEMO_IP" "https://${MGMT_ENDPOINT}/" "被拒（符合預期）"

# ── 9 ─────────────────────────────────────────────────────────────────────
stage "開啟開機自啟"
say "上面全部通過，現在才開啟 Demo 的開機自啟。"
note "提早開啟等於讓 hypervisor 重開機把一個未驗證的設定帶回來。"
gate "開啟 Demo 的開機自啟？"

qm set "$DEMO_VMID" --onboot 1
readback "Demo 的 onboot" "1" "$(qmcfg "$DEMO_VMID" onboot)"

{
  printf '\n注意：%s 與 %s 的經驗性驗證是時間點限定的。\n' \
    "$UAT_ENTRANCE_PORT" "$DEMO_ENTRANCE_PORT"
  printf '它只證明當下可達，不揭露 FortiGate 的 policy 範圍、client pool 或 user group，\n'
  printf '也不保證未來網路變更後仍可達。網路變更後必須重測。\n'
} >> "$PROBES"

say ""
say "探測紀錄："
sed 's/^/    /' "$PROBES"

finish "票 09 完成：重開機後自行恢復，開機自啟已開啟"
say "驗收紀錄：${HOST_STATE}"
say "下一步：./10-delete-retained-source.sh（整項工作最後一個不可逆動作）"
