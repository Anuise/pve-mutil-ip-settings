# 05 — 第一次開機，並把新機器的形狀讀出來

**What to build:** 開機，等 guest agent 回應，然後**讀出新機器實際長什麼樣**——
不是假設範本的名字（`ub-26-4-srv-docker`）就代表 `/srv` 與 Docker 已經是我們要的形狀。

上一輪的教訓正是這個：票 06 通過了驗收，卻沒發現 image layer 根本不在 data-root 底下，
因為沒有人去讀 storage driver。這一票要把那些事實**寫下來**，後面的票才有東西可以對照。

要讀回並記錄的：

- 網路：`ip -4 -o addr`、`ip route`、`/etc/netplan/` 的實際內容。位址必須是
  `172.23.57.12/24`，預設閘道 `172.23.57.1`，而且**不得出現任何 `10.1.2.x` 的位址**。
- 檔案系統：`lsblk`、`findmnt /srv`、`df -hT`。`/srv` 必須是獨立檔案系統，記錄它的
  來源裝置與容量。
- Docker：`docker info` 的 `Docker Root Dir`、`Storage Driver`、`Server Version`；
  `/etc/docker/daemon.json`（若存在）；`du -sh /var/lib/containerd`。
  **不預設 data-root 在哪，讀出來寫下來。**
- 對外通路：DNS 解析 `source.mobagel.com`、`ping 172.23.57.1`、對外連通性。
- guest agent：`qemu-guest-agent` 的服務狀態與版本。

Docker 可用性用實際動作證明：pull 一個小 image、跑一個用後即刪的容器、刪掉。
不看 `docker info` 的結束碼就當作可用。

開機後 `onboot` 仍維持 `0`。

**Blocked by:** 04

**Status:** ready-for-agent

- [ ] VM `running`，guest agent 有回應
- [ ] guest 內位址為 `172.23.57.12/24`，閘道 `172.23.57.1`，**沒有任何 `10.1.2.x` 位址**
- [ ] `/srv` 是獨立檔案系統，來源裝置與容量已記錄
- [ ] Docker 的 `Docker Root Dir`、`Storage Driver`、`Server Version` 已讀回記錄
- [ ] image 實際落在哪個路徑已確認並記錄（含 `/var/lib/containerd` 的用量）
- [ ] DNS 解得到 `source.mobagel.com`，對外連通性正常
- [ ] pull 一個 image 並跑一個用後即刪的容器成功
- [ ] `onboot` 仍為 `0`
- [ ] UAT 的 `10.1.2.57:8081` 不受影響
