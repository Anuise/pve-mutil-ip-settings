#!/usr/bin/env bash
#
# 本目錄 wizard.sh 的測試。不需要 PVE，任何有 bash 的機器都能跑：
#
#     bash wizard.test.sh
#
# 共用的畫面、閘門與讀回驗證由 ../demo-entrance-and-srv-layout/wizard.test.sh
# 涵蓋，這裡只測本 spec 新增的部分，全是「錯了也不會當場爆炸」的那一類：
#  1. 分段的段數算錯 → 少帶最後一段，檔案短一截，而每一個指令都回 0。
#  2. 分段取回／送出的重組與 SHA-256 複驗 —— 複驗本身壞掉的話，內容損毀
#     會被當成成功。
#  3. `pvesm status` 的欄位取錯 → 500 GiB 停止條款拿錯數字去比。
#  4. 對外網段的偵測 → 新機器出現在 10.1.2.x 上而沒有人發現（票 05 的停止條件）。
#  5. vzdump 封存路徑解析錯 → 去驗證一個不存在的檔案。

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

check_contains() { # check_contains "名稱" "應包含" "實際"
  if [[ "$3" == *"$2"* ]]; then
    PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL %s\n       expected to contain: %s\n       actual: %s\n' "$1" "$2" "$3"
  fi
}

echo
echo "分段的段數"
# 少算一段不會讓任何指令回非 0，只會少帶最後那幾個 byte。
check "0 bytes 不需要任何一段" "0|0"   "$(run 'chunk_count 0 256')"
check "不足一段仍算一段"       "0|1"   "$(run 'chunk_count 1 256')"
check "剛好整除"               "0|1"   "$(run 'chunk_count 256 256')"
check "多一個 byte 就多一段"   "0|2"   "$(run 'chunk_count 257 256')"
check "66 MB 分 256 KiB"       "0|255" "$(run 'chunk_count 66650000 262144')"
check "段長為 0 時停止"        "1"     "$(run 'chunk_count 100 0' | cut -d'|' -f1)"

echo
echo "pvesm status 的可用空間"
PVESM='Name             Type     Status           Total            Used       Available        %
VMdisk        zfspool     active     10737418240      7376000000      3361418240   68.69%
local              dir     active       921000000       35000000       886000000    3.80%'

check "取指定儲存池的 Available" "0|3361418240" \
  "$(run 'printf "%s" "$1" | pvesm_avail_kib VMdisk' _ "$PVESM")"
check "不同儲存池取到不同的值" "0|886000000" \
  "$(run 'printf "%s" "$1" | pvesm_avail_kib local' _ "$PVESM")"
check "查不到的儲存池回非 0" "1" \
  "$(run 'printf "%s" "$1" | pvesm_avail_kib nosuch' _ "$PVESM" | cut -d'|' -f1)"

echo
echo "對外網段的偵測（票 05 的停止條件）"
check "私有位址不算對外網段" "0|1" \
  "$(run 'has_lan_addr "eth0=172.23.57.12/24 docker0=172.17.0.1/16"; printf %s $?')"
check "出現 10.1.2.x 就算" "0|0" \
  "$(run 'has_lan_addr "eth0=10.1.2.57/24"; printf %s $?')"
check "只是開頭長得像的位址不算" "0|1" \
  "$(run 'has_lan_addr "eth0=110.1.2.3/24"; printf %s $?')"
check "夾在中間也找得到" "0|0" \
  "$(run 'has_lan_addr "eth0=172.23.57.12/24 eth1=10.1.2.99/24"; printf %s $?')"

echo
echo "vzdump 封存路徑"
VZDUMP="INFO: starting new backup job
INFO: creating vzdump archive '/var/lib/vz/dump/vzdump-qemu-103-2026_08_14-11_02_03.vma.zst'
INFO: archive file size: 12.34GB"

check "從 vzdump 輸出取出封存路徑" \
  "0|/var/lib/vz/dump/vzdump-qemu-103-2026_08_14-11_02_03.vma.zst" \
  "$(run 'printf "%s" "$1" | vzdump_archive_path' _ "$VZDUMP")"
check "取不到路徑時回非 0" "1" \
  "$(run 'printf "INFO: nothing here" | vzdump_archive_path' | cut -d'|' -f1)"

echo
echo "票 01 保全目錄的定位"
check "PRESERVE_DIR 指定時就用它" "0|$PWD" "$(run "PRESERVE_DIR='$PWD' preserve_dir")"
check "指定的目錄不存在時停止" "1" \
  "$(run 'PRESERVE_DIR=/nonexistent/demo-preserve-x preserve_dir' | cut -d'|' -f1)"

echo
echo "分段取回（guest → 主機）"
# guest 由本機的 sh 代打；要驗的是重組與 SHA-256 複驗，不是 qm。
FAKE_GUEST='guest_exec() { sh -c "$2"; }'

pull_case() { # pull_case 內容長度 段長
  run "
    $FAKE_GUEST
    CHUNK_PULL_BYTES=$2
    d=\$(mktemp -d); head -c $1 /dev/urandom > \"\$d/src\"
    pull_guest_blob 103 \"\$d/src\" \"\$d/dest\" >/dev/null 2>&1
    rc=\$?
    if [[ \$rc -eq 0 ]] && cmp -s \"\$d/src\" \"\$d/dest\"
      then printf SAME; else printf 'DIFF(rc=%s)' \$rc; fi
    rm -rf \"\$d\""
}

check "小於一段：內容一致"           "0|SAME" "$(pull_case 40 256)"
check "多段且最後一段不滿：內容一致" "0|SAME" "$(pull_case 1000 256)"
check "剛好整除：內容一致"           "0|SAME" "$(pull_case 512 256)"
check "空檔：內容一致"               "0|SAME" "$(pull_case 0 256)"

# 某一段回了別的東西 —— 這正是主機端重算 SHA-256 要擋下來的事。
r=$(run "
  guest_exec() { case \"\$2\" in *skip=1*) printf 'QUJDRA==';; *) sh -c \"\$2\";; esac; }
  CHUNK_PULL_BYTES=256
  d=\$(mktemp -d); head -c 1000 /dev/urandom > \"\$d/src\"
  pull_guest_blob 103 \"\$d/src\" \"\$d/dest\"; printf REACHED_NEXT_STEP")
check "某一段內容不對時停止" "1" "${r%%|*}"
check_contains "停止時講的是 SHA-256 不符" "SHA-256" "$r"

echo
echo "分段送出（主機 → guest）"

push_case() { # push_case 內容長度 段長
  run "
    $FAKE_GUEST
    CHUNK_PUSH_BYTES=$2
    d=\$(mktemp -d); head -c $1 /dev/urandom > \"\$d/src\"
    push_guest_blob 103 \"\$d/src\" \"\$d/dest\" 0600 >/dev/null 2>&1
    rc=\$?
    if [[ \$rc -eq 0 ]] && cmp -s \"\$d/src\" \"\$d/dest\"
      then printf SAME; else printf 'DIFF(rc=%s)' \$rc; fi
    rm -rf \"\$d\""
}

check "多段且最後一段不滿：內容一致" "0|SAME" "$(push_case 1000 256)"
check "剛好整除：內容一致"           "0|SAME" "$(push_case 512 256)"
check "空檔：內容一致"               "0|SAME" "$(push_case 0 256)"

# guest 端算出來的 SHA-256 不符時要停止，而不是回報成功。
r=$(run "
  guest_exec() {
    case \"\$2\" in
      *sha256sum*) printf '0000000000000000000000000000000000000000000000000000000000000000';;
      *) sh -c \"\$2\";;
    esac
  }
  CHUNK_PUSH_BYTES=256
  d=\$(mktemp -d); head -c 300 /dev/urandom > \"\$d/src\"
  push_guest_blob 103 \"\$d/src\" \"\$d/dest\" 0600; printf REACHED_NEXT_STEP")
check "落地內容與來源不符時停止" "1" "${r%%|*}"

# 附加寫入不可用會重跑的通道：同一段寫兩次就多出 48 KiB，而每個指令都回 0。
check "附加寫入不用可重跑的通道" "0|NONE" \
  "$(run 'declare -f push_guest_blob | grep -q guest_retry_or_abort && printf FOUND || printf NONE')"

echo
if [[ "$FAIL" -eq 0 ]]; then
  printf '\n  %s tests passed\n\n' "$PASS"
else
  printf '\n  %s passed, %s FAILED\n\n' "$PASS" "$FAIL"
  exit 1
fi
