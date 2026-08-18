# 03 — 第一次開機，把新機器的形狀讀出來

**What to build:** 開機，等 guest agent 回應，然後**讀出新機器實際長什麼樣**——
不是假設範本的名字（`ub-26-4-srv-docker`）就代表 `/srv` 與 Docker 已經是我們要的形狀。

上一輪的教訓正是這個（見 [ADR-0004](../../../docs/adr/0004-rebuild-demo-from-template-109.md)）：
驗收通過了，卻沒發現 image layer 根本不在 data-root 底下，因為沒有人去讀 storage
driver。這一票要把那些事實**寫下來**，票 04 與日後的部署才有東西可以對照。

要讀回並記錄的：

- 網路：`ip -4 -o addr`、`ip route`、`/etc/netplan/` 的實際內容。位址必須是
  `172.23.57.12/24`，預設閘道 `172.23.57.1`，而且**不得出現任何 `10.1.2.x` 的位址**
  —— 出現就立刻停止，關機修正 `net0` 後重跑。
- 檔案系統：`lsblk`、`findmnt /srv`、`df -hT`。`/srv` 必須是獨立檔案系統，記錄它的
  來源裝置與容量。
- Docker：`docker info` 的 `Docker Root Dir`、`Storage Driver`、`Server Version`；
  `/etc/docker/daemon.json`（若存在）；`du -sh /var/lib/containerd`。
  **不預設 data-root 在哪，讀出來寫下來。**
- 對外通路：`ping 172.23.57.1`、對外 IP 連通性、DNS 解析。
- 既有 listener：`ss -ltn` 與 guest 上的防火牆狀態（`ufw status`／`nft list ruleset`）。
  票 04 要在 `443` 上起臨時 listener，先知道那個 port 沒被佔用、也沒被 guest 自己擋掉。
- guest agent：`qemu-guest-agent` 的服務狀態與版本。

Docker 可用性用**實際動作**證明，不看 `docker info` 的結束碼：pull `hello-world`、
跑一個 `--rm` 的容器、再把 image 刪掉，並清點容器數與 image 數回到 0。

`onboot` 維持 `0`。要不要開自啟等票 04 驗收過再由人決定。

**Blocked by:** 02

**Status:** needs-rerun —— stage 5 的三個 bug 已修好並在真機驗證過（非 ASCII payload 的 guest-exec 逾時、df -T 與 --output 互斥、du 假設了 Docker 28 的目錄形狀）。驗收項目除了「儲存池空間記錄」以外都已個別實測通過，但整票未跑到 finish
