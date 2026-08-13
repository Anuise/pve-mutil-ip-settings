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

# PVE 的 `qm set --help` 會以非 0 結束；pipefail 下直接 `qm … | grep -q` 會把
# 「支援」誤判成「不支援」，於是票 02 在前置檢查就無故停止。
r=$(run "qm() { printf ' -ciupgrade <boolean>\n'; return 255; }; qm_supports_option ciupgrade && echo SUPPORTED")
check_contains "qm 以非 0 結束仍能判定支援" "SUPPORTED" "$r"

# PVE 的說明把選項印成單破折號，呼叫時卻是雙破折號。兩種都要認得，
# 否則守衛會在支援 ciupgrade 的機器上把票 02 擋在前置檢查。
r=$(run "qm() { printf '  -ciupgrade  <boolean>   (default=1)\n'; }; qm_supports_option ciupgrade && echo SUPPORTED")
check_contains "說明用單破折號時判定支援" "SUPPORTED" "$r"

r=$(run "qm() { printf '  --ciupgrade <boolean>\n'; }; qm_supports_option ciupgrade && echo SUPPORTED")
check_contains "說明用雙破折號時判定支援" "SUPPORTED" "$r"

r=$(run "qm() { printf ' -name <string>\n -cipassword <password>\n'; return 255; }; qm_supports_option ciupgrade || echo UNSUPPORTED")
check_contains "選項不存在時判定不支援" "UNSUPPORTED" "$r"

# 舊版把 `--` 當成選項名傳進來，於是 grep 命中任何一行，守衛形同虛設。
r=$(run "qm() { printf ' -name <string>\n'; }; qm_supports_option ciupgrade || echo UNSUPPORTED")
check_contains "不會因為說明裡有其他選項就誤判支援" "UNSUPPORTED" "$r"

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
if (( FAIL )); then
  printf '\n%d passed, %d FAILED\n\n' "$PASS" "$FAIL"
  exit 1
fi
printf '\n%d passed\n\n' "$PASS"
