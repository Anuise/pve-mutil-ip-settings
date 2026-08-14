#!/usr/bin/env bash
#
# wizard.sh 的測試。不需要 PVE，任何有 bash 的機器都能跑：
#
#     bash wizard.test.sh
#
# 涵蓋的是「錯了但不會當場爆炸」的那幾段：
#  1. 讀回不符時整個序列必須停止，而不是繼續（票 02 的驗收條件）。
#  2. abort 必須印到 stderr —— 它常在 `x=$(guest_exec_or_abort …)` 底下被呼叫，
#     印到 stdout 會被變數吃掉，操作者只看到腳本無聲結束。
#  3. net0 改寫、sshkeys 解碼與金鑰擷取：錯了會弄壞網卡設定或漏列金鑰。
#  4. 報告的 secret 遮蔽與 pipefail 誤判。

set -uo pipefail
LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/wizard.sh"

PASS=0; FAIL=0

# run 'body' [stdin] — 子行程執行 body，印出 "<exit>|<stdout+stderr 單行>"。
run() {
  local out rc
  out=$(printf '%s' "${2-}" | bash -c "source '$LIB'; $1" 2>&1)
  rc=$?
  printf '%s|%s' "$rc" "$(printf '%s' "$out" | tr '\n' ' ')"
}

# run_out / run_err — 只取其中一條串流，用來驗證訊息去了哪裡。
run_out() { printf '%s' "${2-}" | bash -c "source '$LIB'; $1" 2>/dev/null | tr '\n' ' '; }
run_err() { printf '%s' "${2-}" | bash -c "source '$LIB'; $1" 2>&1 1>/dev/null | tr '\n' ' '; }

check() { # check "名稱" "期望" "實際"
  if [[ "$3" == "$2" ]]; then
    PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL %s\n       expected: %s\n       actual:   %s\n' "$1" "$2" "$3"
  fi
}

check_contains() { # check_contains "名稱" "應包含" "實際"
  if [[ "$3" == *"$2"* ]]; then
    PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL %s\n       expected to contain: %s\n       actual: %s\n' "$1" "$2" "$3"
  fi
}

check_lacks() { # check_lacks "名稱" "不應包含" "實際"
  if [[ "$3" != *"$2"* ]]; then
    PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL %s\n       should not contain: %s\n       actual: %s\n' "$1" "$2" "$3"
  fi
}

echo
echo "讀回驗證會停止序列"

r=$(run 'readback "memory" 65536 65536; echo REACHED_NEXT_STEP')
check_contains "讀回相符時繼續下一步" "REACHED_NEXT_STEP" "$r"
check "讀回相符時 exit 0" "0" "${r%%|*}"

r=$(run 'readback "memory" 65536 8192; echo REACHED_NEXT_STEP')
check_lacks "讀回不符時不執行下一步" "REACHED_NEXT_STEP" "$r"
check "讀回不符時 exit 1" "1" "${r%%|*}"
check_contains "讀回不符時印出期望值" "expected: 65536" "$r"

r=$(run 'readback_match "ipconfig0" "ip=172\.23\.57\.12/24(,|$)" "ip=172.23.57.12/24,gw=172.23.57.1"; echo REACHED_NEXT_STEP')
check_contains "readback_match 相符時繼續" "REACHED_NEXT_STEP" "$r"

r=$(run 'readback_match "net0 bridge" "bridge=vmbr3(,|$)" "virtio=AA:BB:CC:DD:EE:FF,bridge=vmbr0"; echo REACHED_NEXT_STEP')
check_lacks "readback_match 不符時不執行下一步" "REACHED_NEXT_STEP" "$r"
check "readback_match 不符時 exit 1" "1" "${r%%|*}"

r=$(run 'abort "boom"; echo REACHED_NEXT_STEP')
check_lacks "abort 後不執行下一步" "REACHED_NEXT_STEP" "$r"

echo
echo "abort 的訊息要看得到（不能被 command substitution 吃掉）"

check "abort 不寫 stdout" "" "$(run_out 'abort "boom"')"
check_contains "abort 寫 stderr" "boom" "$(run_err 'abort "boom"')"
check_contains "readback 失敗細節寫 stderr" "expected: 65536" "$(run_err 'readback "memory" 65536 8192')"
# 這是實際的呼叫形態：訊息若寫 stdout，操作者會完全看不到失敗原因。
check_contains "在 x=\$(…) 底下 abort 仍看得到訊息" "無法讀取" \
  "$(run_err 'f() { abort "無法讀取位址"; }; x=$(f); echo "$x"')"

echo
echo "guest_exec 分辨得出失敗的種類"
# guest_exec_or_abort 依這些回傳碼給出不同的說明，所以它們是契約的一部分。
# 最要緊的是 124：PVE 等到 --timeout 到期會回一份沒有 exitcode 的回應，把它
# 當成 0 的話，「逾時、指令還在跑」會長得跟「成功且無輸出」一模一樣。
ge() { # ge 'qm 的假回應' — 印出 "<exit>|<stdout>"
  local out rc=0
  out=$(bash -c "source '$LIB'; qm() { $1; }; guest_exec 103 cmd" 2>/dev/null) || rc=$?
  printf '%s|%s' "$rc" "$out"
}

check "正常回應" "0|hi" "$(ge 'printf "{\"exitcode\":0,\"out-data\":\"hi\"}"')"
check "guest 內的指令回非 0" "3|" "$(ge 'printf "{\"exitcode\":3}"')"
check "逾時（回應沒有 exitcode）" "124|" "$(ge 'printf "{\"exited\":0}"')"
check "qm guest exec 本身失敗" "125|" "$(ge 'echo boom >&2; exit 255')"
check "回應不是 JSON" "126|" "$(ge 'printf "not json"')"
check "回應是陣列不是物件" "126|" "$(ge 'printf "[1,2,3]"')"
check_contains "逾時時 abort 講的是逾時" "還在 guest 內跑" \
  "$(run_err 'qm() { printf "{\"exited\":0}"; }; guest_exec_or_abort 103 cmd "讀不到"')"

# agent 叫不動時 guest_retry_or_abort 要等它回來再試一次 —— 重跑最貴的一段不該
# 由 agent 打個嗝來決定。重試的訊息必須走 stderr，否則會被 x=$(…) 吃進值裡，
# 所以這裡只收 stdout：期望值就是 out-data 本身，不含任何提示文字。
# 參數是「前幾次要失敗」；qm agent ping 一律成功，wait_agent 才不會真的睡下去。
retry() {
  local out rc=0
  out=$(bash -c "
    source '$LIB'
    N=\$(mktemp); printf 0 > \"\$N\"
    qm() {
      [[ \$1 == agent ]] && return 0
      local n; n=\$(cat \"\$N\"); printf '%s' \$((n + 1)) > \"\$N\"
      (( n < $1 )) && { echo 'guest agent is not running' >&2; return 255; }
      printf '{\"exitcode\":0,\"out-data\":\"%s\"}' \"\$n\"
    }
    guest_retry_or_abort 103 cmd '讀不到'" 2>/dev/null) || rc=$?
  printf '%s|%s' "$rc" "$out"
}

check "agent 一時叫不動：等回來再試就過" "0|1" "$(retry 1)"
check "重試的提示不會混進取回的值" "0|1" "$(retry 1)"
check "agent 一直叫不動：停止" "1|" "$(retry 9)"

echo
echo "確認閘門"

r=$(run 'gate "繼續？"; echo REACHED_NEXT_STEP' 'y
')
check_contains "回答 y 時繼續" "REACHED_NEXT_STEP" "$r"

r=$(run 'gate "繼續？"; echo REACHED_NEXT_STEP' 'n
')
check_lacks "回答 n 時停止" "REACHED_NEXT_STEP" "$r"
check "回答 n 時 exit 1" "1" "${r%%|*}"

r=$(run 'gate "繼續？"; echo REACHED_NEXT_STEP' '')
check_lacks "直接 Enter 視為否定" "REACHED_NEXT_STEP" "$r"

echo
echo "qm config 解析"

QM_STUB='qm() { printf "name: type-ai-platform-demo\nnet0: virtio=BC:24:11:0A:0B:0C,bridge=vmbr0,firewall=1\nmemory: 8192\n"; };'

r=$(run "${QM_STUB} qmcfg 103 net0")
check "qmcfg 取出 net0" "0|virtio=BC:24:11:0A:0B:0C,bridge=vmbr0,firewall=1" "$r"

r=$(run "${QM_STUB} printf '[%s]' \"\$(qmcfg 103 balloon)\"")
check "欄位不存在時輸出空字串" "0|[]" "$r"

# PVE 9 的 `qm set --help` 只印 USAGE 摘要，選項清單要問 `qm help set --verbose`；
# 而 PVE 的 help 又會以非 0 結束，pipefail 下直接 `qm … | grep -q` 會誤判。
# 兩者任一沒處理好，票 02 都會在前置檢查無故停止。
PVE9_QM='qm() {
  if [ "$1" = help ]; then printf "  -ciupgrade  <boolean>   (default=1)\n  -name       <string>\n"; return 255; fi
  printf "USAGE: qm set <vmid> [OPTIONS]\n"; return 255;
};'

r=$(run "${PVE9_QM} qm_supports_option ciupgrade && echo SUPPORTED")
check_contains "PVE 9：選項只在 qm help set --verbose 裡且 qm 回非 0" "SUPPORTED" "$r"

r=$(run "qm() { printf '  --ciupgrade <boolean>\n'; }; qm_supports_option ciupgrade && echo SUPPORTED")
check_contains "說明用雙破折號時判定支援" "SUPPORTED" "$r"

r=$(run "${PVE9_QM} qm_set_options | paste -sd, -")
check "選項清單去掉破折號並排序" "0|ciupgrade,name" "$r"

r=$(run "qm() { printf ' -name <string>\n -cipassword <password>\n'; return 255; }; qm_supports_option ciupgrade || echo UNSUPPORTED")
check_contains "選項不存在時判定不支援" "UNSUPPORTED" "$r"

# 曾經把 `--` 當成選項名傳進來，於是 grep 命中任何一行，守衛形同虛設。
r=$(run "qm() { printf ' -name <string>\n'; }; qm_supports_option ciupgrade || echo UNSUPPORTED")
check_contains "不會因為說明裡有其他選項就誤判支援" "UNSUPPORTED" "$r"

# 問不到清單時必須輸出空字串，讓呼叫端能分辨「確定沒有」與「問不到」——
# 把「問不到」當成「不支援」，就是這次在 PVE 9.2.3 上停住的那個誤判。
r=$(run "qm() { printf 'USAGE: qm set <vmid> [OPTIONS]\n'; return 255; }; printf '[%s]' \"\$(qm_set_options)\"")
check "說明不列選項時輸出空清單" "0|[]" "$r"

echo
echo "net0 改寫保留 MAC 與其他旗標"

r=$(run 'net0_bridge_set "virtio=BC:24:11:0A:0B:0C,bridge=vmbr0,firewall=1" vmbr3')
check "只改 bridge" "0|virtio=BC:24:11:0A:0B:0C,bridge=vmbr3,firewall=1" "$r"

r=$(run 'net0_bridge_set "virtio=BC:24:11:0A:0B:0C,bridge=vmbr0" vmbr3')
check "bridge 在字串結尾" "0|virtio=BC:24:11:0A:0B:0C,bridge=vmbr3" "$r"

r=$(run 'net0_bridge_set "e1000=BC:24:11:0A:0B:0C,bridge=vmbr0,tag=57,mtu=1500" vmbr3')
check "保留 model 與 tag/mtu" "0|e1000=BC:24:11:0A:0B:0C,bridge=vmbr3,tag=57,mtu=1500" "$r"

r=$(run 'net0_bridge_set "virtio=BC:24:11:0A:0B:0C" vmbr3 && echo REACHED_NEXT_STEP')
check_lacks "沒有 bridge= 欄位時回傳失敗" "REACHED_NEXT_STEP" "$r"

r=$(run 'net0_mac "virtio=BC:24:11:0A:0B:0C,bridge=vmbr0,firewall=1"')
check "取出 MAC" "0|BC:24:11:0A:0B:0C" "$r"

r=$(run 'net0_mac "$(net0_bridge_set "virtio=BC:24:11:0A:0B:0C,bridge=vmbr0" vmbr3)"')
check "改寫後 MAC 不變" "0|BC:24:11:0A:0B:0C" "$r"

echo
echo "guest 位址比對（Demo 跑 Docker，scope global 不只一個）"

DOCKER_ADDRS='eth0=172.23.57.12/24 docker0=172.17.0.1/16 br-9f2a=172.18.0.1/16'

r=$(run "readback_contains '位址' '=172.23.57.12/24' '${DOCKER_ADDRS}'; echo REACHED_NEXT_STEP")
check_contains "有 docker0/br-* 時仍認得 Demo 的位址" "REACHED_NEXT_STEP" "$r"

r=$(run "readback_contains '位址' '=172.23.57.12/24' 'docker0=172.17.0.1/16'; echo REACHED_NEXT_STEP")
check_lacks "位址不在清單中時停止" "REACHED_NEXT_STEP" "$r"

r=$(run "readback_contains '位址' '=172.23.57.12/24' 'eth0=172.23.57.120/24'; echo REACHED_NEXT_STEP")
check_lacks "不會把 .120 誤認成 .12" "REACHED_NEXT_STEP" "$r"

echo
echo "sshkeys 解碼與金鑰擷取"

r=$(run 'urldecode "ssh-ed25519%20AAAAC3Nz%20user%40host%0A"')
check "解開 %20 %40 %0A" "0|ssh-ed25519 AAAAC3Nz user@host" "$r"

r=$(run 'urldecode "plain-no-encoding"')
check "沒有編碼時原樣輸出" "0|plain-no-encoding" "$r"

r=$(run "printf 'ssh-rsa AAAAB3rsa deploy@host\n' | ssh_key_bodies")
check "一般 ssh-rsa" "0|AAAAB3rsa" "$r"

# 這三種都是 authorized_keys 的合法寫法。固定取第 2 欄會漏掉後兩種 ——
# 漏掉就等於漏列「重置後會失去存取」的金鑰。
r=$(run "printf 'sk-ssh-ed25519@openssh.com AAAAGnNr yubikey\n' | ssh_key_bodies")
check "FIDO 金鑰型別 sk-*" "0|AAAAGnNr" "$r"

r=$(run "printf 'command=\"/usr/bin/rrsync /srv\",no-pty ssh-ed25519 AAAAC3opts backup\n' | ssh_key_bodies")
check "帶 options 前綴的行" "0|AAAAC3opts" "$r"

r=$(run "printf 'ssh-rsa AAAAB3b bbb\nssh-ed25519 AAAAC3a aaa\n' | ssh_key_bodies | paste -sd, -")
check "多行去重排序" "0|AAAAB3b,AAAAC3a" "$r"

echo
echo "報告的 secret 遮蔽"

r=$(run "printf '//nas/share /mnt cifs username=svc,password=hunter2,vers=3.0 0 0\n' | redact_secrets")
check_lacks "fstab 的 CIFS 密碼不外流" "hunter2" "$r"
check_contains "fstab 只留鍵名" "password=<redacted>" "$r"
check_contains "fstab 其餘欄位保留" "username=svc" "$r"

r=$(run "printf '  \"auth\": \"c2VjcmV0\",\n' | redact_secrets")
check_lacks "daemon.json 的 auth 值不外流" "c2VjcmV0" "$r"
check_contains "daemon.json 只留鍵名" '"auth": "<redacted>"' "$r"

r=$(run "printf 'UUID=abc /srv ext4 defaults 0 2\n' | redact_secrets")
check "沒有 secret 的行原樣輸出" "0|UUID=abc /srv ext4 defaults 0 2" "$r"

echo
echo "fstab 掛載點改寫（票 06）"

FSTAB_SAMPLE='# <file system> <mount point>   <type>  <options>       <dump>  <pass>
# /var/lib/docker was on /dev/vg_data/lv_docker during curtin installation
/dev/disk/by-id/dm-uuid-LVM-AAA /var/lib/docker ext4 defaults 0 1
# /srv was on /dev/vg_data/lv_srv during curtin installation
/dev/disk/by-id/dm-uuid-LVM-BBB /srv ext4 defaults 0 1
/dev/disk/by-id/dm-uuid-LVM-CCC /var ext4 defaults,nodev,nosuid 0 1
/swap.img	none	swap	sw	0	0'

lib_run() { printf '%s\n' "${2-}" | bash -c "source '$LIB'; $1"; }

r=$(lib_run 'fstab_set_mountpoint /var/lib/docker /srv/platform' "$FSTAB_SAMPLE")
check_contains "掛載點改為 /srv/platform" \
  "/dev/disk/by-id/dm-uuid-LVM-AAA /srv/platform ext4 defaults 0 1" "$r"
check_lacks "設定行不再指向舊掛載點" "LVM-AAA /var/lib/docker" "$r"
check_contains "註解原樣保留" "# /var/lib/docker was on" "$r"
check_contains "/srv 那一行不動" "LVM-BBB /srv ext4 defaults 0 1" "$r"
# 掛載選項照 ADR-0002 維持 defaults：Docker 需要在 data-root 建裝置節點與 setuid 檔。
check_lacks "沒有把 /var 的 nodev,nosuid 帶到新掛載點" "/srv/platform ext4 defaults,nodev" "$r"
check_contains "非掛載行原樣保留" "/swap.img" "$r"

r=$(printf 'x /home ext4 defaults 0 1\n' |
  bash -c "source '$LIB'; fstab_set_mountpoint /var/lib/docker /srv/platform"; echo "rc=$?")
check_contains "找不到該掛載點時回傳 1" "rc=1" "$r"

# 兩行同掛載點代表 fstab 已被改過或有殘留，改寫哪一行都是猜；必須停止。
r=$(printf 'a /var/lib/docker ext4 defaults 0 1\nb /var/lib/docker ext4 defaults 0 1\n' |
  bash -c "source '$LIB'; fstab_set_mountpoint /var/lib/docker /srv/platform" 2>/dev/null; echo "rc=$?")
check_contains "同一掛載點超過一行時回傳 2" "rc=2" "$r"
check_lacks "回傳 2 時不輸出半套 fstab" "/srv/platform" "$r"

echo
echo "daemon.json 合併 data-root（票 06）"

DAEMON_JSON='{
  "log-driver": "local",
  "log-opts": {
    "max-size": "100m",
    "max-file": "60",
    "compress": "true"
  }
}'

r=$(lib_run 'daemon_json_with_data_root /srv/platform/docker' "$DAEMON_JSON")
check_contains "寫入 data-root" '"data-root" : "/srv/platform/docker"' "$r"
check_contains "既有 log-driver 保留" '"log-driver" : "local"' "$r"
check_contains "既有 log-opts 保留" '"max-file"' "$r"

r=$(lib_run 'daemon_json_with_data_root /srv/platform/docker' \
  '{"data-root":"/var/lib/docker","log-driver":"local"}')
check_lacks "既有 data-root 被覆寫而非重複" '/var/lib/docker' "$r"
check_contains "覆寫後其餘鍵仍在" '"log-driver"' "$r"

r=$(printf '' | bash -c "source '$LIB'; daemon_json_with_data_root /srv/platform/docker")
check_contains "沒有 daemon.json 時產生只含 data-root 的物件" '"data-root"' "$r"

r=$(printf 'not json\n' |
  bash -c "source '$LIB'; daemon_json_with_data_root /srv/platform/docker" 2>/dev/null; echo "rc=$?")
check_contains "無法解析時回傳 1 而不是寫出壞檔" "rc=1" "$r"

echo
echo "nftables entrance port 規則插入（票 08）"

NFT_BASE='#!/usr/sbin/nft -f
flush ruleset

define ext_if = "eth0"
define int_if = "eth1"
define private_net = 172.23.57.0/24
define vpn_nat_peer = 192.168.255.253/32

table inet edge_filter {
    chain forward {
        type filter hook forward priority filter; policy drop;
        ct state invalid drop
        ct state established,related accept
        iifname $ext_if oifname $int_if ip saddr $vpn_nat_peer ip daddr 172.23.57.11 tcp dport 443 ct status dnat accept
        iifname $int_if oifname $ext_if ip saddr $private_net ip daddr 10.1.2.0/24 drop
        limit rate 5/second burst 10 packets counter log prefix "edge-forward-drop " flags all drop
    }
}

table ip edge_nat {
    chain prerouting {
        type nat hook prerouting priority dstnat; policy accept;
        iifname $ext_if ip saddr $vpn_nat_peer tcp dport 8081 dnat to 172.23.57.11:443
    }

    chain postrouting {
        type nat hook postrouting priority srcnat; policy accept;
        iifname $ext_if oifname $int_if ip saddr $vpn_nat_peer ip daddr 172.23.57.11 tcp dport 443 snat to 172.23.57.1
        oifname $ext_if ip saddr $private_net masquerade
    }
}'

NFT_NEW=$(lib_run 'nft_add_entrance_rules 8082 172.23.57.12 443' "$NFT_BASE")

# chain_body NAME — 從 stdin 取出某條 chain 的內容。規則落錯 chain 是「設定載得進去
# 但行為不對」的那一類錯誤，只 grep 全檔看不出來。
chain_body() {
  awk -v n="$1" '$0 ~ ("chain " n " \\{") { inside = 1; next }
                 inside && /^[[:space:]]*}[[:space:]]*$/ { inside = 0 }
                 inside'
}

fwd_body=$(printf '%s\n' "$NFT_NEW" | chain_body forward | tr '\n' ' ')
pre_body=$(printf '%s\n' "$NFT_NEW" | chain_body prerouting | tr '\n' ' ')
post_body=$(printf '%s\n' "$NFT_NEW" | chain_body postrouting | tr '\n' ' ')

check_contains "forward 放行限定來源、目的與轉譯 port" \
  'ip saddr $vpn_nat_peer ip daddr 172.23.57.12 tcp dport 443 ct status dnat accept' "$fwd_body"
check_contains "DNAT 落在 prerouting" 'tcp dport 8082 dnat to 172.23.57.12:443' "$pre_body"
check_contains "SNAT 落在 postrouting 且指向 Edge 私有位址" \
  'ip daddr 172.23.57.12 tcp dport 443 snat to 172.23.57.1' "$post_body"

check_lacks "DNAT 不會落到 forward" "dnat to" "$fwd_body"
check_lacks "forward 放行不會落到 postrouting" "ct status dnat accept" "$post_body"

# 新規則必須排在 log/drop 之前，否則永遠不會被評估到。
fwd_new_line=$(printf '%s\n' "$NFT_NEW" | chain_body forward | grep -n '172.23.57.12' | cut -d: -f1)
fwd_drop_line=$(printf '%s\n' "$NFT_NEW" | chain_body forward | grep -n 'edge-forward-drop' | cut -d: -f1)
check "forward 新規則排在 log/drop 之前" "yes" \
  "$( [[ -n "$fwd_new_line" && -n "$fwd_drop_line" && "$fwd_new_line" -lt "$fwd_drop_line" ]] && echo yes || echo no)"

# 具體的 SNAT 必須排在通用 masquerade 之前。
post_new_line=$(printf '%s\n' "$NFT_NEW" | chain_body postrouting |
  grep -n 'ip daddr 172.23.57.12' | cut -d: -f1)
post_masq_line=$(printf '%s\n' "$NFT_NEW" | chain_body postrouting | grep -n 'masquerade' | cut -d: -f1)
check "SNAT 排在 masquerade 之前" "yes" \
  "$( [[ -n "$post_new_line" && -n "$post_masq_line" && "$post_new_line" -lt "$post_masq_line" ]] && echo yes || echo no)"

check_contains "既有 8081 的 DNAT 不動" "tcp dport 8081 dnat to 172.23.57.11:443" "$NFT_NEW"
check_contains "既有 UAT 的 forward 放行不動" "ip daddr 172.23.57.11 tcp dport 443" "$NFT_NEW"
check_contains "預設拒絕政策未放寬" "policy drop;" "$NFT_NEW"
check_contains "縮排與既有規則一致" \
  "        iifname \$ext_if ip saddr \$vpn_nat_peer tcp dport 8082 dnat to 172.23.57.12:443" "$NFT_NEW"

# 重跑同一支腳本不該再插一次。
r=$(printf '%s\n' "$NFT_NEW" |
  bash -c "source '$LIB'; nft_add_entrance_rules 8082 172.23.57.12 443" 2>/dev/null; echo "rc=$?")
check_contains "已存在同 port 的 DNAT 時回傳 2" "rc=2" "$r"

# 已配給其他環境的 port：同樣以 2 停止，不會靜悄悄把 UAT 換掉。
r=$(printf '%s\n' "$NFT_BASE" |
  bash -c "source '$LIB'; nft_add_entrance_rules 8081 172.23.57.12 443" 2>/dev/null; echo "rc=$?")
check_contains "port 已配給其他環境時回傳 2" "rc=2" "$r"

r=$(printf 'table inet edge_filter {\n}\n' |
  bash -c "source '$LIB'; nft_add_entrance_rules 8082 172.23.57.12 443" 2>/dev/null; echo "rc=$?")
check_contains "找不到錨點時回傳 1" "rc=1" "$r"
check_lacks "找不到錨點時不輸出半套設定" "8082" "$r"

echo
echo "Keycloak compose 產生（票 11）"

# render-keycloak-compose.sh 把 docker inspect 抽出的欄位轉成 compose。
# 唯一會改的東西是 realm import 的 bind mount source —— 改錯是「容器起得來、
# realm 匯不到」的那種錯，所以這裡用假的 inspect 欄位把它釘住。
RENDER="$(dirname "$LIB")/demo-stack/render-keycloak-compose.sh"
FIELDS=$(mktemp -d)
trap 'rm -rf "$FIELDS"' EXIT

printf 'quay.io/keycloak/keycloak:26.0\n' > "$FIELDS/image"
printf '/opt/keycloak/bin/kc.sh\n' > "$FIELDS/entrypoint"
printf 'start-dev\n--import-realm\n' > "$FIELDS/cmd"
printf 'bind\t/home/mobagel/type-ai-platform-demo/type-ai-platform-infra/base/keycloak/realm-typeai.json\t/opt/keycloak/data/import/realm-typeai.json\tfalse\n' \
  > "$FIELDS/mounts"
printf 'typeai-net\n' > "$FIELDS/networks"

r=$(bash "$RENDER" "$FIELDS" /home/mobagel/type-ai-platform-demo \
      /srv/platform/type-ai-platform-demo)

check_contains "沿用原 image" "image: 'quay.io/keycloak/keycloak:26.0'" "$r"
check_contains "沿用原容器名" "container_name: typeai-demo-kc" "$r"
check_contains "重開機恢復靠 restart policy" "restart: unless-stopped" "$r"
check_contains "env 走 env_file，不進 YAML" "env_file:" "$r"
check_contains "沿用原 entrypoint" "'/opt/keycloak/bin/kc.sh'" "$r"
check_contains "沿用原啟動參數" "- 'start-dev'" "$r"
check_contains "realm bind mount 已改指新位置" \
  "- '/srv/platform/type-ai-platform-demo/type-ai-platform-infra/base/keycloak/realm-typeai.json:/opt/keycloak/data/import/realm-typeai.json:ro'" \
  "$r"
check_lacks "不再引用 /home 的舊路徑" "/home/mobagel" "$r"
# 沿用原網路：換網路會弄丟 keycloak 原本連得到的東西。
check_contains "沿用容器原本的網路" "- typeai-net" "$r"
check_contains "原網路以 external 引用，不由本 stack 建立" "external: true" "$r"
# 不 publish port：Demo 只經 audited 的 entrance port 被存取。
check_lacks "不發佈任何 port" "ports:" "$r"

# 不在舊前綴底下的 bind mount 不該被改。
printf 'bind\t/etc/localtime\t/etc/localtime\tfalse\n' > "$FIELDS/mounts"
r=$(bash "$RENDER" "$FIELDS" /home/mobagel/type-ai-platform-demo \
      /srv/platform/type-ai-platform-demo)
check_contains "前綴以外的 bind mount 原樣保留" "- '/etc/localtime:/etc/localtime:ro'" "$r"

printf 'bind\t/srv/data\t/data\ttrue\n' > "$FIELDS/mounts"
r=$(bash "$RENDER" "$FIELDS" /home/mobagel/type-ai-platform-demo \
      /srv/platform/type-ai-platform-demo)
check_contains "可寫的 bind mount 不加 :ro" "- '/srv/data:/data'" "$r"

# volume 型 mount 代表有資料要跟著走，交給人判斷而不是猜。
printf 'volume\t/var/lib/docker/volumes/abc/_data\t/data\ttrue\n' > "$FIELDS/mounts"
r=$(bash "$RENDER" "$FIELDS" /home/mobagel/type-ai-platform-demo \
      /srv/platform/type-ai-platform-demo 2>/dev/null; echo "rc=$?")
check_contains "遇到非 bind 的 mount 時停止" "rc=3" "$r"

printf '' > "$FIELDS/image"
printf 'bind\t/etc/localtime\t/etc/localtime\tfalse\n' > "$FIELDS/mounts"
r=$(bash "$RENDER" "$FIELDS" /a /b 2>/dev/null; echo "rc=$?")
check_contains "抽不到 image 時停止" "rc=1" "$r"

echo
if (( FAIL )); then
  printf '\n%d passed, %d FAILED\n\n' "$PASS" "$FAIL"
  exit 1
fi
printf '\n%d passed\n\n' "$PASS"
