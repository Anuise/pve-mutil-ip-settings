#!/usr/bin/env bash
#
# 本目錄 wizard.sh 的測試。不需要 PVE，任何有 bash 的機器都能跑：
#
#     bash wizard.test.sh
#
# 共用的畫面、閘門、讀回驗證由 ../demo-entrance-and-srv-layout/wizard.test.sh 涵蓋，
# 分段傳輸與儲存池解析由 ../demo-rebuild-from-template/wizard.test.sh 涵蓋。
# 這裡測本 spec 的三個函式，三個都是「錯了也不會當場爆炸」的那一類：
#
#  1. 解除註解取錯行 → nft -c -f 仍會通過（規則語法沒錯），但放行的可能是別的
#     目的地，或者三條只解開兩條 —— DNAT 通了而 forward 沒放行，症狀是「規則
#     裝好了但打不通」，而每個指令都回 0。
#  2. listener 檢查認了 loopback → 「有 listener」通過，但 DNAT 永遠沒人回答。
#     票 04 的驗收會失敗在最貴的一步（人已經連上 VPN 在等）。
#  3. read_guest 走錯 guest 通道 → 前面每一段讀回都成功，直到 du 掃完 data-root
#     讓 agent 打了個嗝，整票就停在 stage 5。這件事實際發生過。

set -uo pipefail
LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/wizard.sh"

PASS=0; FAIL=0

# run 'body' [$0 [$1 …]] — 子行程執行 body，印出 "<exit>|<stdout+stderr 單行>"。
run() {
  local out rc
  out=$(bash -c "source '$LIB'; $1" "${@:2}" 2>&1)
  rc=$?
  printf '%s|%s' "$rc" "$(printf '%s' "$out" | tr '\n' ' ')"
}

check() { # check "名稱" "期望" "實際"
  if [[ "$3" == "$2" ]]; then
    PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL %s\n       expected: %s\n       actual:   %s\n' "$1" "$2" "$3"
  fi
}

echo
echo "read_guest 走的是會等 agent 回來的那條通道（票 03 stage 5）"
# 票 03 stage 5 實際死在 read_guest 的 du -sh，而它當時走不重試的 guest_exec_or_abort：
#     qm: VM 103 qga command 'guest-exec' failed - got timeout
#     ✗ 無法讀取：image 實際落在哪裡（qm guest exec 沒能送出，看上面那行 qm:）
# 讀回全是唯讀指令，重跑一次無害；agent 打個嗝不該要人重跑整票。
# 內層用 set -euo pipefail，與 03-first-boot.sh 一致 —— abort 是在 command
# substitution 裡的 pipeline 左側退出的，少了 pipefail 就攔不下來。
# qm agent ping 一律成功，wait_agent 才不會真的睡下去。
read_guest_rc() { # read_guest_rc 前幾次要失敗 — 印出 "<exit>|<紀錄檔內容單行>"
  local out rc=0
  out=$(RGFAIL="$1" RGERR="qga command 'guest-exec' failed - got timeout" bash -c '
    set -euo pipefail
    source "$0"
    STATE_DIR=$(mktemp -d); REPORT="$STATE_DIR/report.md"; : > "$REPORT"
    N=$(mktemp); printf 0 > "$N"
    qm() {
      [[ $1 == agent ]] && return 0
      local n; n=$(cat "$N"); printf %s $((n + 1)) > "$N"
      (( n < RGFAIL )) && { printf "%s\n" "$RGERR" >&2; return 255; }
      printf "{\"exitcode\":0,\"out-data\":\"data-root: /var/lib/docker\"}"
    }
    read_guest "image 實際落在哪裡" "du -sh /var/lib/docker" >/dev/null
    tr "\n" " " < "$REPORT"' "$LIB" 2>/dev/null) || rc=$?
  printf '%s|%s' "$rc" "$out"
}

RG_REPORT=' ### image 實際落在哪裡  ``` data-root: /var/lib/docker ``` '

check "一次就成功：讀回寫進紀錄" "0|${RG_REPORT}" "$(read_guest_rc 0)"
check "guest-exec 逾時：等 agent 回來再試就過" "0|${RG_REPORT}" "$(read_guest_rc 1)"
check "重試的提示不會混進紀錄" "0" "$(read_guest_rc 1 | grep -c '重試')"
check "agent 一直叫不動：停止，紀錄不留半截" "1|" "$(read_guest_rc 9)"

# ── 待測資料 ──────────────────────────────────────────────────────────────
# Edge 上實際那一份的骨架：8081 已生效，8082 的三條被註解，另有中文說明註解。

CONF='table inet edge_filter {
    chain forward {
        type filter hook forward priority filter; policy drop;
        iifname $ext_if oifname $int_if ip saddr $vpn_nat_peer ip daddr 172.23.57.11 tcp dport 443 ct status dnat accept
        # 8082 到 172.23.57.12:443：已產生，尚未安裝到 Edge。
        # iifname $ext_if oifname $int_if ip saddr $vpn_nat_peer ip daddr 172.23.57.12 tcp dport 443 ct status dnat accept
        limit rate 5/second burst 10 packets counter log prefix "edge-forward-drop " flags all drop
    }
}

table ip edge_nat {
    chain prerouting {
        type nat hook prerouting priority dstnat; policy accept;
        iifname $ext_if ip saddr $vpn_nat_peer tcp dport 8081 dnat to 172.23.57.11:443
        # 已產生、尚未安裝（見 forward chain 的說明）
        # iifname $ext_if ip saddr $vpn_nat_peer tcp dport 8082 dnat to 172.23.57.12:443
    }

    chain postrouting {
        type nat hook postrouting priority srcnat; policy accept;
        iifname $ext_if oifname $int_if ip saddr $vpn_nat_peer ip daddr 172.23.57.11 tcp dport 443 snat to 172.23.57.1
        # 已產生、尚未安裝（見 forward chain 的說明）
        # iifname $ext_if oifname $int_if ip saddr $vpn_nat_peer ip daddr 172.23.57.12 tcp dport 443 snat to 172.23.57.1
        oifname $ext_if ip saddr $private_net masquerade
    }
}'

echo
echo "解除註解（票 04 的安裝動作）"

OUT=$(printf '%s\n' "$CONF" |
  bash -c "source '$LIB'; nft_uncomment_entrance_rules 8082 172.23.57.12 443")
check "三條規則都解除註解" "3" \
  "$(printf '%s\n' "$OUT" | grep -cE '^[[:space:]]+iifname .*172\.23\.57\.12')"
check "沒有任何規則行還留著 #" "0" \
  "$(printf '%s\n' "$OUT" | grep -cE '^[[:space:]]*#[[:space:]]*iifname')"
check "中文說明註解不動" "3" \
  "$(printf '%s\n' "$OUT" | grep -c '尚未安裝')"
check "縮排原樣保留（8 個空白）" "3" \
  "$(printf '%s\n' "$OUT" | grep -cE '^        iifname .*172\.23\.57\.12')"
check "policy drop 未被動到" "1" "$(printf '%s\n' "$OUT" | grep -c 'policy drop;')"
check "UAT 的 8081 規則未被動到" "1" \
  "$(printf '%s\n' "$OUT" | grep -c 'tcp dport 8081 dnat to 172.23.57.11:443')"
check "行數不變（只改內容，不增刪行）" \
  "$(printf '%s\n' "$CONF" | wc -l | tr -d ' ')" \
  "$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')"

echo
echo "解除註解的停止條件"
# 已經裝好了還再裝一次 → 會出現兩條同 port 的 DNAT，而 nft 不會抱怨。
check "已有未被註解的 8082 DNAT 時回 2" "2" \
  "$(run 'printf "%s\n" "$1" | nft_uncomment_entrance_rules 8082 172.23.57.12 443' _ "$OUT" |
     cut -d'|' -f1)"
check "找不到那三條時回 1" "1" \
  "$(run 'printf "%s\n" "$1" | nft_uncomment_entrance_rules 9999 172.23.57.99 443' _ "$CONF" |
     cut -d'|' -f1)"
# 三缺一比三條全缺更危險：DNAT 通了而 forward 沒放行，或反之。
PARTIAL=$(printf '%s\n' "$CONF" | grep -v 'tcp dport 8082 dnat to')
check "只找到兩條時也回 1，不做半套" "1" \
  "$(run 'printf "%s\n" "$1" | nft_uncomment_entrance_rules 8082 172.23.57.12 443' _ "$PARTIAL" |
     cut -d'|' -f1)"
check "目的地 IP 不符時不解除註解" "1" \
  "$(run 'printf "%s\n" "$1" | nft_uncomment_entrance_rules 8082 172.23.57.13 443' _ "$CONF" |
     cut -d'|' -f1)"

echo
echo "為什麼不能直接用 nft_add_entrance_rules"
# 註解行裡就有 "tcp dport 8082 dnat to"，新增版會誤判成「port 已被佔用」而停止。
# 這一條測的是那個誤判仍然存在 —— 它是 nft_uncomment_entrance_rules 存在的理由。
check "新增版對著被註解的規則會回 2" "2" \
  "$(run 'printf "%s\n" "$1" | nft_add_entrance_rules 8082 172.23.57.12 443' _ "$CONF" |
     cut -d'|' -f1)"

echo
echo "listener 檢查（票 04 的停止條款）"
SS_OK='State  Recv-Q Send-Q Local Address:Port  Peer Address:Port
LISTEN 0      4096   0.0.0.0:443         0.0.0.0:*
LISTEN 0      4096   0.0.0.0:22          0.0.0.0:*'
SS_LO='State  Recv-Q Send-Q Local Address:Port  Peer Address:Port
LISTEN 0      4096   127.0.0.1:443       0.0.0.0:*'
SS_V6='State  Recv-Q Send-Q Local Address:Port  Peer Address:Port
LISTEN 0      4096   [::]:443            [::]:*'
SS_V6LO='State  Recv-Q Send-Q Local Address:Port  Peer Address:Port
LISTEN 0      4096   [::1]:443           [::]:*'
SS_NEAR='State  Recv-Q Send-Q Local Address:Port  Peer Address:Port
LISTEN 0      4096   0.0.0.0:4430        0.0.0.0:*
LISTEN 0      4096   0.0.0.0:8443        0.0.0.0:*'
SS_NONE='State  Recv-Q Send-Q Local Address:Port  Peer Address:Port
LISTEN 0      4096   0.0.0.0:22          0.0.0.0:*'

listener_rc() { # listener_rc 'ss 輸出' PORT
  run "printf '%s\n' \"\$1\" | ss_reachable_listener $2; printf %s \$?" _ "$1"
}

check "綁 0.0.0.0 算可達"        "0|0" "$(listener_rc "$SS_OK" 443)"
check "只綁 127.0.0.1 不算"      "0|1" "$(listener_rc "$SS_LO" 443)"
check "綁 [::] 算可達"           "0|0" "$(listener_rc "$SS_V6" 443)"
check "只綁 [::1] 不算"          "0|1" "$(listener_rc "$SS_V6LO" 443)"
check "4430 與 8443 不算 443"    "0|1" "$(listener_rc "$SS_NEAR" 443)"
check "只有 SSH 時不算"          "0|1" "$(listener_rc "$SS_NONE" 443)"
check "空輸入不算"               "0|1" "$(listener_rc "" 443)"
check "同一份輸出裡的 22 找得到" "0|0" "$(listener_rc "$SS_OK" 22)"
# 表頭含 "Address:Port"，peer 欄位是 "0.0.0.0:*"；Send-Q 的 4096 不帶冒號。
# 三者都不該被當成 port。
check "表頭與 peer 欄位不被誤讀" "0|1" "$(listener_rc "$SS_NONE" 4096)"

echo
if [[ "$FAIL" -eq 0 ]]; then
  printf '\n  %s tests passed\n\n' "$PASS"
else
  printf '\n  %s passed, %s FAILED\n\n' "$PASS" "$FAIL"
  exit 1
fi
