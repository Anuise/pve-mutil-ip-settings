#!/usr/bin/env bash
#
# 票 06 — 把 Docker 的 LV 從 /var/lib/docker 改掛到 /srv/platform。
#
# 不是把 Docker 搬離 OS 卷：/var/lib/docker 本身就是 vg_data 上的 80G 專屬 LV。
# 這裡改的是同一顆 LV 的掛載點，內容隨 LV 移動，收進 docker/ 只是同檔案系統的
# rename，不跨檔案系統、不需要額外空間。理由見 ADR-0002。
#
# 每一步都有具名的反向動作（印在該 stage 的 note），所以整段不靠快照也可逆。
# 票 02 的快照 pre-demo-entrance-* 是最後手段：它早於 private bridge 遷移與
# Cloud-Init 重置，回退到它會把那兩件一起退掉。
#
# Blocked by 票 05（決策已寫回 spec）。在 PVE host 上以 root 執行。

set -euo pipefail
# shellcheck source=wizard.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/wizard.sh"

TS=$(date +%Y%m%d-%H%M%S)
GUEST_STATE="/root/demo-storage-${TS}"
HOST_STATE="$(pwd)/demo-storage-${TS}"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# 停機前後都要收的清單：<檔名>:<指令>
INVENTORY=(
  "images:docker images --format '{{.Repository}}:{{.Tag}} {{.ID}}' | sort"
  "containers:docker ps -a --format '{{.Names}} {{.Image}} {{.State}}' | sort"
  "volumes:docker volume ls --format '{{.Driver}} {{.Name}}' | sort"
  "counts:docker info --format 'Containers={{.Containers}} Running={{.ContainersRunning}} Images={{.Images}}'"
)

# collect_inventory DIR — 把上列清單收進 guest 的 DIR。DIR 必須在被搬的卷之外。
collect_inventory() {
  local dir="$1" item
  guest_exec_or_abort "$DEMO_VMID" "mkdir -p '$dir'" "無法建立 $dir" >/dev/null
  for item in "${INVENTORY[@]}"; do
    guest_exec_or_abort "$DEMO_VMID" "${item#*:} > '${dir}/${item%%:*}.txt'" \
      "無法收集 ${item%%:*}" >/dev/null
  done
}

TOTAL_STAGES=11
banner "票 06 — Docker 的 LV 改掛到 ${PLATFORM_ROOT}"

# ── 1 ─────────────────────────────────────────────────────────────────────
stage "前置檢查"
need_pve
readback "Demo 電源狀態" "running" "$(qmstatus "$DEMO_VMID")"
qm agent "$DEMO_VMID" ping >/dev/null 2>&1 || abort "guest agent 沒有回應"
readback_contains "guest 內部位址" "=${DEMO_IP}/24" "$(guest_global_addrs "$DEMO_VMID")"

readback "Docker 目前的 data-root" "$DOCKER_OLD_MOUNT" \
  "$(guest_exec_or_abort "$DEMO_VMID" "docker info --format '{{.DockerRootDir}}'" \
     "無法讀取 data-root" | tr -d '\n')"
readback "${DOCKER_OLD_MOUNT} 目前由獨立 LV 提供" "/dev/mapper/vg_data-lv_docker" \
  "$(guest_exec_or_abort "$DEMO_VMID" "findmnt -rno SOURCE '${DOCKER_OLD_MOUNT}'" \
     "${DOCKER_OLD_MOUNT} 不是獨立掛載點，前提不成立" | tr -d '\n')"
readback "/srv 已掛載（${PLATFORM_ROOT} 要掛在其下）" "/dev/mapper/vg_data-lv_srv" \
  "$(guest_exec_or_abort "$DEMO_VMID" "findmnt -rno SOURCE /srv" "/srv 未掛載" | tr -d '\n')"

running=$(guest_exec_or_abort "$DEMO_VMID" \
  "docker info --format '{{.ContainersRunning}}'" "無法讀取容器狀態" | tr -d '\n')
readback "running containers（tutorial 的安全順序以此為前提）" "0" "$running"

# ── 2 ─────────────────────────────────────────────────────────────────────
stage "記錄搬移前的狀態"
say "清單寫進 guest 的 ${GUEST_STATE}，那在 lv_os 上，不在被搬的卷裡。"
note "反向動作：無（唯讀）。"
gate "開始收集？"

collect_inventory "${GUEST_STATE}/before"

# /var/lib/docker 的目錄權限要跟著 Docker 走到 /srv/platform/docker：
# 改掛之後檔案系統根目錄會沿用它，而 Docker 的 0710 會擋住票 07 的非 root 通行。
DOCKER_MODE=$(guest_exec_or_abort "$DEMO_VMID" "stat -c %a '${DOCKER_OLD_MOUNT}'" \
  "無法讀取 ${DOCKER_OLD_MOUNT} 的權限" | tr -d '\n')
readback_match "${DOCKER_OLD_MOUNT} 的目錄權限" '^[0-7]{3,4}$' "$DOCKER_MODE"

mkdir -p "$HOST_STATE"
for item in "${INVENTORY[@]}"; do
  pull_guest_file "$DEMO_VMID" "${GUEST_STATE}/before/${item%%:*}.txt" \
    "${HOST_STATE}/before-${item%%:*}.txt"
done
say ""
sed 's/^/    /' "${HOST_STATE}/before-counts.txt"
say "    images=$(wc -l < "${HOST_STATE}/before-images.txt") \
containers=$(wc -l < "${HOST_STATE}/before-containers.txt") \
volumes=$(wc -l < "${HOST_STATE}/before-volumes.txt")"

# ── 3 ─────────────────────────────────────────────────────────────────────
stage "停止 Docker"
say "順序固定：docker.socket → docker.service → containerd.service。"
note "socket 先停，否則 socket activation 會在後面的步驟把 daemon 叫回來。"
note "反向動作：systemctl start containerd docker.socket docker。"
gate "停止 Docker？"

guest_exec_or_abort "$DEMO_VMID" \
  "systemctl stop docker.socket && systemctl stop docker.service && systemctl stop containerd.service" \
  "停止 Docker 失敗" >/dev/null
readback "docker.service" "inactive" \
  "$(guest_exec "$DEMO_VMID" "systemctl is-active docker.service" | tr -d '\n')"
readback "docker.socket" "inactive" \
  "$(guest_exec "$DEMO_VMID" "systemctl is-active docker.socket" | tr -d '\n')"
readback "containerd.service" "inactive" \
  "$(guest_exec "$DEMO_VMID" "systemctl is-active containerd.service" | tr -d '\n')"

# ── 4 ─────────────────────────────────────────────────────────────────────
stage "備份 /etc/fstab 與 /etc/docker/daemon.json"
note "反向動作：cp -a ${GUEST_STATE}/etc-fstab /etc/fstab（daemon.json 同理）。"

guest_exec_or_abort "$DEMO_VMID" \
  "cp -a /etc/fstab '${GUEST_STATE}/etc-fstab'" "備份 /etc/fstab 失敗" >/dev/null
ok "已備份 /etc/fstab"
if guest_exec "$DEMO_VMID" "test -f /etc/docker/daemon.json" >/dev/null; then
  guest_exec_or_abort "$DEMO_VMID" \
    "cp -a /etc/docker/daemon.json '${GUEST_STATE}/etc-docker-daemon.json'" \
    "備份 daemon.json 失敗" >/dev/null
  ok "已備份 /etc/docker/daemon.json"
else
  warn "guest 上沒有 /etc/docker/daemon.json，稍後會新建一份只含 data-root 的"
fi

pull_guest_file "$DEMO_VMID" "${GUEST_STATE}/etc-fstab" "${HOST_STATE}/etc-fstab"
cp "${HOST_STATE}/etc-fstab" "$WORK/fstab"

# ── 5 ─────────────────────────────────────────────────────────────────────
stage "改寫 fstab 的掛載點"
say "${DOCKER_OLD_MOUNT} → ${PLATFORM_ROOT}，掛載選項維持 defaults。"
note "不可比照 /var 套 nodev,nosuid：Docker 需要在 data-root 建裝置節點與 setuid 檔。"
note "反向動作：把備份的 /etc/fstab 複製回去。"

rc=0
fstab_set_mountpoint "$DOCKER_OLD_MOUNT" "$PLATFORM_ROOT" < "$WORK/fstab" > "$WORK/fstab.new" || rc=$?
case "$rc" in
  0) ;;
  1) abort "/etc/fstab 沒有 ${DOCKER_OLD_MOUNT} 這個掛載點" ;;
  2) abort "/etc/fstab 有多行指向 ${DOCKER_OLD_MOUNT}，改哪一行都是猜；請人工確認" ;;
  *) abort "改寫 /etc/fstab 失敗（rc=${rc}）" ;;
esac

say ""
diff -u "$WORK/fstab" "$WORK/fstab.new" | sed 's/^/    /' || true
say ""
gate "這個差異正確？"

guest_put_file "$DEMO_VMID" /etc/fstab 0644 < "$WORK/fstab.new"
guest_exec_or_abort "$DEMO_VMID" "systemctl daemon-reload" "daemon-reload 失敗" >/dev/null
readback "fstab 中 ${PLATFORM_ROOT} 的掛載選項" "defaults" \
  "$(guest_exec_or_abort "$DEMO_VMID" \
     "awk '\$2 == \"${PLATFORM_ROOT}\" {print \$4}' /etc/fstab" \
     "無法讀回 fstab" | tr -d '\n')"

# ── 6 ─────────────────────────────────────────────────────────────────────
stage "umount 並確認 ${DOCKER_OLD_MOUNT} 為空"
note "反向動作：mount ${DOCKER_OLD_MOUNT}（先把 fstab 還原）。"
gate "卸載 ${DOCKER_OLD_MOUNT}？"

guest_exec_or_abort "$DEMO_VMID" "umount '${DOCKER_OLD_MOUNT}'" \
  "卸載失敗；確認沒有行程持有該路徑（fuser -vm ${DOCKER_OLD_MOUNT}）" >/dev/null
ok "已卸載"

leftover=$(guest_exec_or_abort "$DEMO_VMID" "ls -A '${DOCKER_OLD_MOUNT}' | wc -l" \
  "無法列出 ${DOCKER_OLD_MOUNT}" | tr -d '\n')
if [[ "$leftover" != "0" ]]; then
  warn "${DOCKER_OLD_MOUNT} 卸載後仍有 ${leftover} 個項目："
  guest_exec "$DEMO_VMID" "ls -la '${DOCKER_OLD_MOUNT}'" | sed 's/^/    /' || true
  human_action "這些內容在 LV 掛載前就被遮蔽在下面。不自行刪除或合併，請人工判斷。"
  abort "${DOCKER_OLD_MOUNT} 卸載後非空"
fi
ok "${DOCKER_OLD_MOUNT} 已確認為空，目錄保留"

# ── 7 ─────────────────────────────────────────────────────────────────────
stage "掛載 ${PLATFORM_ROOT} 並把 Docker 內容收進 docker/"
say "同一顆 LV、同一個檔案系統，收進子目錄只是 rename。"
note "lost+found 留在檔案系統根目錄，不併進 docker/。"
note "反向動作：把 docker/ 的內容移回 ${PLATFORM_ROOT}、rmdir docker、umount、還原 fstab、mount ${DOCKER_OLD_MOUNT}。"
gate "掛載並收攏？"

guest_exec_or_abort "$DEMO_VMID" "
set -e
mkdir -p '${PLATFORM_ROOT}'
mount '${PLATFORM_ROOT}'
mkdir -p '${PLATFORM_ROOT}/docker'
find '${PLATFORM_ROOT}' -mindepth 1 -maxdepth 1 ! -name docker ! -name lost+found \
  -exec mv -t '${PLATFORM_ROOT}/docker' {} +
chown root:root '${PLATFORM_ROOT}' '${PLATFORM_ROOT}/docker'
chmod ${DOCKER_MODE} '${PLATFORM_ROOT}/docker'
chmod 0755 '${PLATFORM_ROOT}'
mkdir -p '${PLATFORM_ROOT}/app-data'
" "掛載或收攏失敗" >/dev/null

readback "${PLATFORM_ROOT} 的來源" "/dev/mapper/vg_data-lv_docker" \
  "$(guest_exec_or_abort "$DEMO_VMID" "findmnt -rno SOURCE '${PLATFORM_ROOT}'" \
     "${PLATFORM_ROOT} 未掛載" | tr -d '\n')"
readback "${PLATFORM_ROOT} 未被套上 nodev/nosuid" "clean" \
  "$(guest_exec_or_abort "$DEMO_VMID" \
     "findmnt -rno OPTIONS '${PLATFORM_ROOT}' | grep -q 'nodev\\|nosuid' && echo dirty || echo clean" \
     "無法讀取掛載選項" | tr -d '\n')"
readback "${PLATFORM_ROOT} 的目錄權限（票 07 的非 root 內容要能通行）" "755" \
  "$(guest_exec_or_abort "$DEMO_VMID" "stat -c %a '${PLATFORM_ROOT}'" "無法讀取權限" | tr -d '\n')"
readback "${PLATFORM_ROOT}/docker 的目錄權限（沿用原 data-root）" "$DOCKER_MODE" \
  "$(guest_exec_or_abort "$DEMO_VMID" "stat -c %a '${PLATFORM_ROOT}/docker'" "無法讀取權限" | tr -d '\n')"

# ── 8 ─────────────────────────────────────────────────────────────────────
stage "daemon.json 指向新的 data-root"
note "只合併 data-root，既有的 log-driver 與 log-opts 原樣保留。"
note "反向動作：把備份的 daemon.json 複製回去（沒有備份就刪掉新建的那份）。"

: > "$WORK/daemon.json"
if guest_exec "$DEMO_VMID" "test -f /etc/docker/daemon.json" >/dev/null; then
  guest_exec_or_abort "$DEMO_VMID" "cat /etc/docker/daemon.json" \
    "無法讀取 daemon.json" > "$WORK/daemon.json"
fi
daemon_json_with_data_root "${PLATFORM_ROOT}/docker" < "$WORK/daemon.json" > "$WORK/daemon.json.new" ||
  abort "現有的 /etc/docker/daemon.json 無法解析；請人工修正後重跑本 stage"

say ""
sed 's/^/    /' "$WORK/daemon.json.new"
say ""
gate "這份 daemon.json 正確？"

guest_exec_or_abort "$DEMO_VMID" "mkdir -p /etc/docker" "無法建立 /etc/docker" >/dev/null
guest_put_file "$DEMO_VMID" /etc/docker/daemon.json 0644 < "$WORK/daemon.json.new"

# ── 9 ─────────────────────────────────────────────────────────────────────
stage "啟動 Docker 並逐項比對"
note "反向動作：停止 Docker，回到 stage 8 的反向動作。"
gate "啟動 containerd 與 docker？"

guest_exec_or_abort "$DEMO_VMID" \
  "systemctl start containerd.service && systemctl start docker.service" \
  "啟動 Docker 失敗；journalctl -u docker -n 50 可看原因" >/dev/null
readback "docker.service" "active" \
  "$(guest_exec "$DEMO_VMID" "systemctl is-active docker.service" | tr -d '\n')"
readback "Docker 的 data-root" "${PLATFORM_ROOT}/docker" \
  "$(guest_exec_or_abort "$DEMO_VMID" "docker info --format '{{.DockerRootDir}}'" \
     "無法讀取 data-root" | tr -d '\n')"

collect_inventory "${GUEST_STATE}/after"
for item in "${INVENTORY[@]}"; do
  name="${item%%:*}"
  pull_guest_file "$DEMO_VMID" "${GUEST_STATE}/after/${name}.txt" "${HOST_STATE}/after-${name}.txt"
  if diff -u "${HOST_STATE}/before-${name}.txt" "${HOST_STATE}/after-${name}.txt" \
       > "${HOST_STATE}/diff-${name}.txt"; then
    ok "${name} 與搬移前逐項相符"
  else
    warn "${name} 與搬移前不符："
    sed 's/^/    /' "${HOST_STATE}/diff-${name}.txt"
    abort "${name} 在改掛前後不一致"
  fi
done

# ── 10 ────────────────────────────────────────────────────────────────────
stage "用後即刪的容器驗證儲存可用"
note "用既有 image 起一顆用完就刪的容器，不啟動原本那三顆 Exited 的容器 ——"
note "它們在搬移前就是停的，儲存工作不改變 workload 狀態。"

probe_out=$(guest_exec_or_abort "$DEMO_VMID" \
  "docker run --rm alpine:3 sh -c 'echo storage-ok > /tmp/p && cat /tmp/p'" \
  "用後即刪的容器跑不起來；儲存或 daemon 有問題" | tr -d '\r\n')
readback "容器內寫入再讀回" "storage-ok" "$probe_out"
readback "容器數量未因驗證而增加" \
  "$(tr -d '\n' < "${HOST_STATE}/after-counts.txt")" \
  "$(guest_exec_or_abort "$DEMO_VMID" \
     "docker info --format 'Containers={{.Containers}} Running={{.ContainersRunning}} Images={{.Images}}'" \
     "無法讀取容器數量" | tr -d '\n')"

# ── 11 ────────────────────────────────────────────────────────────────────
stage "重新開機後自動恢復"
say "改掛的真正驗收是重開機後 fstab 自己把它掛回來。"
warn "若重開機後 ${PLATFORM_ROOT} 沒掛上，Demo 可能停在 emergency mode。"
note "救援：PVE console 進 Demo，把 ${GUEST_STATE}/etc-fstab 複製回 /etc/fstab 後重開。"
gate "重新開機 Demo？"

reboot_and_wait "$DEMO_VMID"

readback "${PLATFORM_ROOT} 重開機後的來源" "/dev/mapper/vg_data-lv_docker" \
  "$(guest_exec_or_abort "$DEMO_VMID" "findmnt -rno SOURCE '${PLATFORM_ROOT}'" \
     "${PLATFORM_ROOT} 重開機後沒有自動掛回" | tr -d '\n')"
say ""
guest_exec_or_abort "$DEMO_VMID" \
  "findmnt -o TARGET,SOURCE,FSTYPE,OPTIONS '${PLATFORM_ROOT}' /srv" \
  "無法讀取掛載表" | sed 's/^/    /'
readback "Docker 的 data-root（重開機後重新讀回）" "${PLATFORM_ROOT}/docker" \
  "$(guest_exec_or_abort "$DEMO_VMID" "docker info --format '{{.DockerRootDir}}'" \
     "無法讀取 data-root" | tr -d '\n')"

require_free_pct "$DEMO_VMID" "$PLATFORM_ROOT"
verify_uat_entrance

finish "票 06 完成：${PLATFORM_ROOT} 由原 Docker LV 提供"
say "搬移前後的清單與差異：${HOST_STATE}"
say "guest 內的備份與清單：${GUEST_STATE}"
say "下一步：./07-migrate-app-data.sh"
