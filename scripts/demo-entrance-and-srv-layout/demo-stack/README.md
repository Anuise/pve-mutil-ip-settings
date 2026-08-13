# Demo stack 定義

Demo（VM 103）上 `172.23.57.12:443` 這個端點的定義。由
[`11-demo-443-endpoint.sh`](../11-demo-443-endpoint.sh) 推進 guest 的
`/srv/platform/type-ai-platform-demo/deploy/`。

## 這裡有什麼

| 檔案 | 用途 |
| --- | --- |
| `compose.yml` | nginx（`typeai-demo-proxy`）、憑證具名 volume、stack 網路 |
| `nginx/default.conf` | 443 的 TLS 終結、`/healthz`、根路徑 |
| `nginx/index.html` | 根路徑的靜態頁，說明應用本體尚未部署 |
| `render-keycloak-compose.sh` | 依 `docker inspect` 產生 `compose.keycloak.yml` |
| `compose.keycloak.yml` | 上一列的產物，票 11 執行後由操作者放回這裡 |

重建：

```bash
docker compose -f compose.yml -f compose.keycloak.yml up -d
```

## 這裡刻意沒有什麼

**應用本體。** 不 build frontend／backend images、不產生 secrets、不跑資料庫
migration、不匯入 Keycloak realm、不動 model cache。見
[ADR-0003](../../../docs/adr/0003-demo-443-endpoint-not-application-deployment.md)。
因此 `10.1.2.57:8082` 的驗收語意是「可達、TLS、回應可與 UAT 區分」。

**`typeai-demo-pg`。** 那顆 66.65MB 匿名 volume 就是它的資料；交給 Compose 管
會拿到一顆新的空 volume，等於刪掉資料庫。它以
`docker update --restart unless-stopped` 取得重開機恢復，不重建。

**keycloak 的環境變數。** 在 guest 的 `deploy/keycloak.env`（mode 0600），
由 `docker inspect` 原樣取出，不進 repo。

**發佈的 port（nginx 以外）。** keycloak 沿用原本的網路但不發佈任何 port ——
Demo 只經 audited 的 entrance port 被存取。

**guest 內的 DOCKER-USER 防火牆規則。** UAT 有一組限制 443 來源的規則；Demo
沒有，因為 spec 沒有要求，而 private bridge 上除了 Edge 沒有別的來源。這是與
UAT 已知且刻意的差異，不是遺漏。

## 憑證

自簽憑證放具名 volume `typeai-demo_nginx-certs`，比照 UAT：重建容器不會換憑證，
刪掉 volume 才會 —— 換憑證等於要求使用者再做一次瀏覽器例外。
fingerprint 記在 guest 的 root 擁有檔案 `/etc/type-ai-platform/demo-nginx-cert.sha256`。

不引入 DNS、hostname routing、憑證機構或公開信任憑證。
