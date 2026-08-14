---
status: accepted
---

# 放棄就地轉移，以範本 109 重建 Demo

Phase 2 的就地轉移已完成票 06（`lv_docker` 改掛 `/srv/platform`）與票 07（checkout 搬到
`/srv/platform`，逐檔 SHA-256 全數相符）。執行過程暴露三件事：

1. **ADR-0002 的目標只達成一半。** Demo 的 Docker 使用 containerd image store
   （`docker info` 回報 `Storage Driver: overlayfs`），image layer 位於 `/var/lib/containerd`
   （1.3G），不在 data-root 底下。搬 data-root 移動了 volume、容器 metadata 與 log，
   沒有把 image 移出 OS 磁碟。票 06 的驗收（容器可跑、清單逐項相符）通過，卻無法揭露
   這件事 —— 因為那些 layer 從來就不在被搬的那顆 LV 上。
2. **guest agent 是單點且會自己壞掉。** qemu-guest-agent 在 11 小時的高頻使用後膨脹到
   1.9 GB 並停止回應（`systemd`：`Consumed 22min 22.632s CPU time over 11h 19min,
   1.9G memory peak`），只能靠重開機復原。它是私有 guest 的唯一通道。
3. **現存的服務憑證 2026-09-09 到期**（簽發於 2026-08-10，`CN=10.1.2.57`），而 ADR-0001
   把 8082 定為**永久**入口。沿用它等於入口 26 天後自己斷掉。

同時，Demo 的用途由「展示既有部署」改為「在 `/srv` 內開發 `type-ai-platform-demo`」。
既有 VM 上累積的狀態 —— 手動啟動的三顆容器、2026-08-10 的憑證、兩份 693M checkout、
`/var/lib/docker` 的歷史遺跡 —— 對新用途沒有價值，只有維護成本。

決定：**銷毀 VM 103，從範本 109（`ub-26-4-srv-docker`）完整複製一台新的 VM 103**，
沿用同一個 VMID、名稱、私有位址 `172.23.57.12` 與 `vmbr3`，在 `/srv` 內重新 clone repo。

本 ADR 取代 ADR-0002 與 ADR-0003。ADR-0001（8082 為 Demo 的永久入口）不變。

## Considered Options

- **繼續就地轉移（票 11 → 08 → 09 → 10）。** 已投入的工作可保留，但要接受一台狀態不明的
  機器：image 仍在 OS 磁碟、憑證 26 天後過期、`/srv/typeai-demo` 底下混著手工放的
  secret 與 log，而票 10 還要在這之上做不可逆的刪除。新用途不需要其中任何一項。
- **就地轉移，另外把 containerd root 也搬到 `/srv/platform`。** 補上 ADR-0002 的缺口，
  但要再停一次 Docker、搬 1.3G、重驗 7 個 image 與 3 顆容器，換來的仍是同一台舊機器 ——
  修一個已經要丟掉的東西。
- **從範本 109 重建。** 選這個：範本本身就叫 `ub-26-4-srv-docker`，`/srv` 與 Docker 的
  形狀由範本保證而不是由九張票堆出來；一次拿到乾淨的 Ubuntu 26.04；image 與 layer 的
  落點由新機器的預設決定，不必逆推八個月的歷史。代價是舊機器上不在 repo 裡的東西
  必須先保全，且銷毀不可逆。

## Consequences

- **不可逆。** `qm destroy 103` 會同時刪掉四顆磁碟（100G + 200G + 500G + cloudinit）與
  快照 `pre-demo-entrance-20260813`。回復點改由銷毀前的 `vzdump` 全機備份提供，那是
  唯一的回頭路，必須先驗證存在且可讀，才准銷毀。
- **舊機器上有不在 repo 裡的東西。** `/srv/typeai-demo/` 底下有 `demo-password`、
  `kc-admin-password`、`kc-token`、`seed-client-secret`、`service-token-secret`、
  `nginx.conf` 與 `試用說明.md`；`/home/mobagel/.ssh/` 有 GitLab deploy key
  `id_ed25519_mobagel_gitlab`（見 ADR-0005）；`typeai-demo-pg` 有 66.65MB 的資料庫
  volume。保全這些是重建的**第一張票**，不是收尾註腳。這些檔案一律不進 repo。
- **VMID、名稱與位址沿用。** repo 內的 nftables ruleset、runbook 配置表、port map 與
  ADR-0001 全部寫著 VM 103 / Demo / `172.23.57.12`。換 ID 會讓文件分岔而換不到任何東西。
  代價是必須先銷毀再複製，中間有一段沒有 Demo 的空窗。
- **記憶體與核心維持 65536 / 8**，與被取代的 VM 同一個規格範圍。範本預設 8192 對
  Keycloak + Postgres + backend + frontend + e2e 太小。要縮小是停機後 `qm set --memory`
  的小事，本次不動這個變數。
- **磁碟採範本原樣**（scsi0 100G + scsi11 200G），不帶舊機器那顆從未使用的 500G。
  `/srv` 的實際容量與掛載來源必須在首次開機時讀回確認，不假設。
- **不設 cipassword。** 範本帶的 `ciuser: mobagel` 與共用的 ci-template SSH key 沿用，
  不新增任何憑證。主要通道仍是 guest agent。
- **`vmbr3` 與靜態位址必須在第一次開機之前設好。** 範本預設 `bridge=vmbr0` 與 `ip=dhcp`；
  以該設定開機會讓新機器出現在對外側，正是票 02 整套安全性要避免的事。
- **對外通路已驗證可用且不需改動。** 舊 Demo 在 `vmbr3` 上以 `172.23.57.1`（Edge）為
  預設閘道即可解析 `source.mobagel.com` 並連得出去。新機器沿用同一組設定，`git clone`
  與 image pull 不需要在 Edge 上新增任何規則。
- **8082 入口與 443 端點的工作延後。** 新機器上沒有服務在 443，票 08（Edge 開通 8082）
  維持未執行。ADR-0001 的配置保留給 Demo，不轉派他用。
- 舊 spec `.scratch/demo-entrance-and-srv-layout/` 與其腳本保留為歷史並標記 superseded；
  票 08 的 nftables 規則產生器日後開通入口時仍可直接用。
