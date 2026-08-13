# Demo（VM 103）盤點報告

產生時間：2026-08-13T14:31:19+08:00
來源：PVE host 經 qemu-guest-agent，全部為唯讀指令
用途：票 05 Phase 2 搬移機制決策的實際數字依據

每一節都記錄了取得該數字的指令，可直接重新執行覆算。
本報告只記錄設定的**鍵名**；密碼、token 與授權欄位的值在寫入前已遮蔽為 `<redacted>`。

## /home/mobagel 的大小與結構

### 總大小

```console
$ du -sh /home/mobagel
8.1G	/home/mobagel
```

### 兩層目錄用量（大到小）

```console
$ du -h --max-depth=2 /home/mobagel 2>/dev/null | sort -rh | head -40
8.1G	/home/mobagel
4.5G	/home/mobagel/.claude
4.4G	/home/mobagel/.claude/remote
1.5G	/home/mobagel/.vscode-server
1.4G	/home/mobagel/.vscode-server/cli
694M	/home/mobagel/type-ai-platform-demo
665M	/home/mobagel/.cache
656M	/home/mobagel/.cache/ms-playwright
483M	/home/mobagel/.venvs
472M	/home/mobagel/type-ai-platform-demo/type-ai-platform-frontend
465M	/home/mobagel/.venvs/typeai-backend
163M	/home/mobagel/.local
156M	/home/mobagel/.npm
140M	/home/mobagel/type-ai-platform-demo/type-ai-platform-backend
139M	/home/mobagel/.claude/projects
109M	/home/mobagel/.local/share
108M	/home/mobagel/.npm/_npx
54M	/home/mobagel/.local/bin
48M	/home/mobagel/.npm/_cacache
32M	/home/mobagel/type-ai-platform-demo/.git
28M	/home/mobagel/type-ai-platform-demo/deliverables
19M	/home/mobagel/rfp-workspace
19M	/home/mobagel/.vscode-server/data
18M	/home/mobagel/.venvs/rfp
15M	/home/mobagel/type-ai-platform-demo/.claude
7.8M	/home/mobagel/rfp-workspace/_extracted
7.4M	/home/mobagel/.cache/typescript
5.7M	/home/mobagel/type-ai-platform-demo/type-ai-platform-docs
4.6M	/home/mobagel/rfp-workspace/98-rawdata
4.1M	/home/mobagel/rfp-workspace/07-baseline
1.5M	/home/mobagel/type-ai-platform-demo/.scratch
1.2M	/home/mobagel/rfp-workspace/06-partner
1.2M	/home/mobagel/.vscode-server/extensions
852K	/home/mobagel/.cache/claude-cli-nodejs
792K	/home/mobagel/type-ai-platform-demo/.agents
536K	/home/mobagel/.cache/fontconfig
500K	/home/mobagel/rfp-workspace/_analysis
352K	/home/mobagel/.npm/_logs
348K	/home/mobagel/.claude/tasks
340K	/home/mobagel/.claude/shell-snapshots
```

### 頂層內容

```console
$ ls -la /home/mobagel
total 136
drwxr-x--- 16 mobagel mobagel  4096 Aug 11 09:53 .
drwxr-xr-x  4 root    root     4096 Jun 11 15:08 ..
drwxr-x---  3 mobagel mobagel  4096 Aug  7 13:51 .agents
-rw-------  1 mobagel mobagel  2951 Aug  9 13:42 .bash_history
-rw-r--r--  1 mobagel mobagel   220 Feb 13 20:16 .bash_logout
-rw-r--r--  1 mobagel mobagel  3797 Aug  5 12:51 .bashrc
drwx------  9 mobagel mobagel  4096 Aug 10 20:53 .cache
drwxrwxr-x 11 mobagel mobagel  4096 Aug  7 13:51 .claude
-rw-------  1 mobagel mobagel 42258 Aug 11 09:53 .claude.json
drwxr-x---  5 mobagel mobagel  4096 Aug  5 12:51 .config
drwx------  4 mobagel mobagel  4096 Aug  5 11:01 .copilot
drwx------  3 mobagel mobagel  4096 Aug  9 13:42 .docker
drwxrwxr-x  3 mobagel mobagel  4096 Aug  5 12:44 .dotnet
-rw-------  1 mobagel mobagel    55 Aug  5 10:52 .git-credentials
-rw-rw-r--  1 mobagel mobagel   133 Aug  5 10:50 .gitconfig
drwxrwxr-x  4 mobagel mobagel  4096 Aug  5 12:52 .local
drwxrwxr-x  5 mobagel mobagel  4096 Aug  6 10:58 .npm
-rw-r--r--  1 mobagel mobagel   833 Aug  5 12:51 .profile
drwx------  2 mobagel mobagel  4096 Aug  5 10:50 .ssh
drwxrwxr-x  4 mobagel mobagel  4096 Aug  5 12:49 .venvs
drwxr-x---  5 mobagel mobagel  4096 Aug 11 09:50 .vscode-server
-rw-rw-r--  1 mobagel mobagel    26 Aug  5 12:51 .zshrc
drwxrwxr-x 15 mobagel mobagel  4096 Aug  5 11:58 rfp-workspace
drwxrwxr-x 15 mobagel mobagel  4096 Aug 10 18:51 type-ai-platform-demo
```

### 專案 checkout（含 .git 的目錄）

```console
$ find /home/mobagel -maxdepth 4 -type d -name .git 2>/dev/null | sed 's#/.git$##' | while read -r d; do printf '%s\trevision=%s\tsize=%s\n' "$d" "$(git -C "$d" rev-parse HEAD 2>/dev/null || echo unknown)" "$(du -sh "$d" 2>/dev/null | cut -f1)"; done
/home/mobagel/type-ai-platform-demo	revision=unknown	size=694M
```

### user-level systemd services

```console
$ ls -la /home/mobagel/.config/systemd/user 2>/dev/null || echo '(no user-level units)'
(no user-level units)
```

## Docker 現況

### data-root 與物件數量

```console
$ docker info --format 'DockerRootDir={{.DockerRootDir}} Containers={{.Containers}} Running={{.ContainersRunning}} Images={{.Images}}'
DockerRootDir=/var/lib/docker Containers=3 Running=0 Images=7
```

### daemon.json

```console
$ cat /etc/docker/daemon.json 2>/dev/null || echo '(no /etc/docker/daemon.json)'
{
  "log-driver": "local",
  "log-opts": {
    "max-size": "100m",
    "max-file": "60",
    "compress": "true"
  }
}
```

### 磁碟用量彙總

```console
$ docker system df
TYPE            TOTAL     ACTIVE    SIZE      RECLAIMABLE
Images          7         3         1.206GB   127.6kB (0%)
Containers      3         0         151MB     151MB (100%)
Local Volumes   1         1         66.65MB   0B (0%)
Build Cache     9         0         6.201MB   95.32kB
```

### containers

```console
$ docker ps -a --format '{{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}'
typeai-demo-proxy	nginx:1.27-alpine	Exited (0) 2 days ago	
typeai-demo-kc	quay.io/keycloak/keycloak:26.0	Exited (143) 2 days ago	
typeai-demo-pg	postgres:18-alpine	Exited (0) 2 days ago	
```

### images

```console
$ docker images --format '{{.Repository}}:{{.Tag}}\t{{.Size}}\t{{.ID}}'
hello-world-model:v1	6.84MB	a0085228b1e1
probe-model:v0	4.85kB	d303dd1b566e
postgres:18-alpine	433MB	9a8afca54e78
alpine:3	13MB	28bd5fe8b56d
alpine:latest	13MB	28bd5fe8b56d
busybox:latest	6.81MB	dc2d74b28e4c
nginx:1.27-alpine	74.5MB	65645c7bb6a0
quay.io/keycloak/keycloak:26.0	691MB	09a381c715ab
```

### volumes

```console
$ docker volume ls --format '{{.Driver}}\t{{.Name}}'
local	97404eea437c9a3b7bf0185520a3c5ad6d95ada2ca01ff1fd61ae2795aeac3b3
```

### data-root 實際佔用

```console
$ du -sh $(docker info --format '{{.DockerRootDir}}') 2>/dev/null
65M	/var/lib/docker
```

## 目前提供 443 與 80 的服務

### host listener

```console
$ ss -ltnp 2>/dev/null | awk 'NR==1 || $4 ~ /:(80|443)$/'
State  Recv-Q Send-Q Local Address:Port Peer Address:PortProcess                                                 
```

### container port 發佈

```console
$ docker ps --format '{{.Names}}\t{{.Ports}}' | grep -E ':(80|443)->' || echo '(no container publishes 80/443)'
(no container publishes 80/443)
```

## 容量與剩餘空間

### 區塊裝置

```console
$ lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT
NAME                        SIZE TYPE FSTYPE      MOUNTPOINT
sda                         100G disk             
├─sda1                        1G part vfat        /boot/efi
├─sda2                        2G part ext4        /boot
└─sda3                     96.9G part LVM2_member 
  ├─vg_os-lv_root            30G lvm  ext4        /
  ├─vg_os-lv_var             12G lvm  ext4        /var
  ├─vg_os-lv_var_tmp          6G lvm  ext4        /var/tmp
  ├─vg_os-lv_var_log         20G lvm  ext4        /var/log
  ├─vg_os-lv_var_log_audit   10G lvm  ext4        /var/log/audit
  └─vg_os-lv_home            15G lvm  ext4        /home
sdb                         200G disk LVM2_member 
├─vg_data-lv_docker          80G lvm  ext4        /var/lib/docker
├─vg_data-lv_containerd      50G lvm  ext4        /var/lib/containerd
└─vg_data-lv_srv             20G lvm  ext4        /srv
sdc                         500G disk             
└─sdc1                      500G part xfs         /data/model-cache
sr0                           4M rom  iso9660     
sr1                        1024M rom              
```

### volume groups

```console
$ vgs
  VG      #PV #LV #SN Attr   VSize    VFree  
  vg_data   1   3   0 wz--n- <200.00g <50.00g
  vg_os     1   6   0 wz--n-  <96.95g  <3.95g
```

### logical volumes

```console
$ lvs -o lv_name,vg_name,lv_size,data_percent,lv_path
  LV               VG      LSize  Data%  Path                       
  lv_containerd    vg_data 50.00g        /dev/vg_data/lv_containerd 
  lv_docker        vg_data 80.00g        /dev/vg_data/lv_docker     
  lv_srv           vg_data 20.00g        /dev/vg_data/lv_srv        
  lv_home          vg_os   15.00g        /dev/vg_os/lv_home         
  lv_root          vg_os   30.00g        /dev/vg_os/lv_root         
  lv_var           vg_os   12.00g        /dev/vg_os/lv_var          
  lv_var_log       vg_os   20.00g        /dev/vg_os/lv_var_log      
  lv_var_log_audit vg_os   10.00g        /dev/vg_os/lv_var_log_audit
  lv_var_tmp       vg_os    6.00g        /dev/vg_os/lv_var_tmp      
```

### 檔案系統用量

```console
$ df -hT -x tmpfs -x devtmpfs -x squashfs
Filesystem                         Type      Size  Used Avail Use% Mounted on
/dev/mapper/vg_os-lv_root          ext4       30G  9.7G   19G  35% /
efivarfs                           efivarfs  256K  146K  106K  59% /sys/firmware/efi/efivars
/dev/sda2                          ext4      2.0G  188M  1.7G  11% /boot
/dev/mapper/vg_os-lv_home          ext4       15G  8.1G  6.0G  58% /home
/dev/sda1                          vfat      1.1G  6.4M  1.1G   1% /boot/efi
/dev/mapper/vg_data-lv_srv         ext4       20G  3.9M   19G   1% /srv
/dev/mapper/vg_os-lv_var           ext4       12G  1.2G   10G  11% /var
/dev/sdc1                          xfs       500G   18G  482G   4% /data/model-cache
/dev/mapper/vg_os-lv_var_tmp       ext4      5.9G  1.6M  5.6G   1% /var/tmp
/dev/mapper/vg_data-lv_docker      ext4       79G   67M   75G   1% /var/lib/docker
/dev/mapper/vg_data-lv_containerd  ext4       49G  1.3G   46G   3% /var/lib/containerd
/dev/mapper/vg_os-lv_var_log       ext4       20G  217M   19G   2% /var/log
/dev/mapper/vg_os-lv_var_log_audit ext4      9.8G  2.5G  6.8G  28% /var/log/audit
```

### 掛載表

```console
$ findmnt -o TARGET,SOURCE,FSTYPE,SIZE,USED,AVAIL,USE% -t ext4,xfs,btrfs
TARGET                  SOURCE                             FSTYPE   SIZE   USED  AVAIL USE%
/                       /dev/mapper/vg_os-lv_root          ext4    29.4G   9.6G  18.2G  33%
├─/boot                 /dev/sda2                          ext4     1.9G 187.3M   1.6G  10%
├─/home                 /dev/mapper/vg_os-lv_home          ext4    14.7G     8G     6G  55%
├─/srv                  /dev/mapper/vg_data-lv_srv         ext4    19.5G   3.9M  18.5G   0%
├─/var                  /dev/mapper/vg_os-lv_var           ext4    11.7G   1.2G   9.9G  10%
│ ├─/var/tmp            /dev/mapper/vg_os-lv_var_tmp       ext4     5.8G   1.5M   5.5G   0%
│ ├─/var/lib/docker     /dev/mapper/vg_data-lv_docker      ext4    78.2G  66.4M  74.1G   0%
│ ├─/var/lib/containerd /dev/mapper/vg_data-lv_containerd  ext4    48.9G   1.3G  45.1G   3%
│ └─/var/log            /dev/mapper/vg_os-lv_var_log       ext4    19.5G 216.7M  18.3G   1%
│   └─/var/log/audit    /dev/mapper/vg_os-lv_var_log_audit ext4     9.7G   2.5G   6.7G  26%
└─/data/model-cache     /dev/sdc1                          xfs    499.8G  17.9G 481.8G   4%
```

### fstab

```console
$ cat /etc/fstab
# /etc/fstab: static file system information.
#
# Use 'blkid' to print the universally unique identifier for a
# device; this may be used with UUID= as a more robust way to name devices
# that works even if disks are added and removed. See fstab(5).
#
# <file system> <mount point>   <type>  <options>       <dump>  <pass>
# / was on /dev/vg_os/lv_root during curtin installation
/dev/disk/by-id/dm-uuid-LVM-vuM8hlAHqIeYEfi8eNIC2PSthImMkJ170JE7telKOSdwH56VOTShyDzeU56piQKC / ext4 defaults 0 1
# /var was on /dev/vg_os/lv_var during curtin installation
/dev/disk/by-id/dm-uuid-LVM-vuM8hlAHqIeYEfi8eNIC2PSthImMkJ17YlJjOnUrOFeLroUH3AzV1dVpdSp3cWxw /var ext4 defaults,nodev,nosuid 0 1
# /var/tmp was on /dev/vg_os/lv_var_tmp during curtin installation
/dev/disk/by-id/dm-uuid-LVM-vuM8hlAHqIeYEfi8eNIC2PSthImMkJ174nmTKm6EaYQtqlTvG33oCGUZpN8QQYpZ /var/tmp ext4 defaults,nodev,nosuid,noexec 0 1
# /var/lib/docker was on /dev/vg_data/lv_docker during curtin installation
/dev/disk/by-id/dm-uuid-LVM-UycAE3azYfddErHtUO2eEmmp3nfXlkdAXRfc5AnljuMRJZazaNtlt5vuQYOWOCrK /var/lib/docker ext4 defaults 0 1
# /var/lib/containerd was on /dev/vg_data/lv_containerd during curtin installation
/dev/disk/by-id/dm-uuid-LVM-UycAE3azYfddErHtUO2eEmmp3nfXlkdAxek8N82tZUmncOPefieCneLSU9fXt3vO /var/lib/containerd ext4 defaults 0 1
# /srv was on /dev/vg_data/lv_srv during curtin installation
/dev/disk/by-id/dm-uuid-LVM-UycAE3azYfddErHtUO2eEmmp3nfXlkdAWr0dYU2HybE6cZ3fAYWBTA2mrEPKXM9k /srv ext4 defaults 0 1
# /var/log was on /dev/vg_os/lv_var_log during curtin installation
/dev/disk/by-id/dm-uuid-LVM-vuM8hlAHqIeYEfi8eNIC2PSthImMkJ17gU6jKfI1MsTRWVItx6CEVT7nUGfR7H7p /var/log ext4 defaults,nodev,nosuid,noexec 0 1
# /home was on /dev/vg_os/lv_home during curtin installation
/dev/disk/by-id/dm-uuid-LVM-vuM8hlAHqIeYEfi8eNIC2PSthImMkJ17puVXNenGt8ntb5mN0FhBYoFFySw7BABX /home ext4 defaults,nodev,nosuid 0 1
# /var/log/audit was on /dev/vg_os/lv_var_log_audit during curtin installation
/dev/disk/by-id/dm-uuid-LVM-vuM8hlAHqIeYEfi8eNIC2PSthImMkJ17G0fO9BPxAaDc8dAulEjLe3CNCQZDM5se /var/log/audit ext4 defaults,nodev,nosuid,noexec 0 1
# /boot was on /dev/sda2 during curtin installation
/dev/disk/by-uuid/0605615c-03f7-422a-9655-722f1deff8f4 /boot ext4 defaults 0 1
# /boot/efi was on /dev/sda1 during curtin installation
/dev/disk/by-uuid/EA50-0F5D /boot/efi vfat rw,uid=0,gid=0,fmask=0177,dmask=0077 0 1
/swap.img	none	swap	sw	0	0
tmpfs /tmp tmpfs defaults,rw,nosuid,nodev,noexec,relatime 0 0
tmpfs /dev/shm tmpfs rw,nosuid,nodev,noexec,inode64 0 0
UUID=238cc650-9f31-4c50-ad78-be438f271b04 /data/model-cache xfs defaults 0 0
```

## 引用 /home/mobagel 絕對路徑的設定

### container bind mounts

```console
$ docker ps -aq | while read -r c; do docker inspect -f '{{.Name}}{{range .Mounts}} {{.Source}}->{{.Destination}}{{end}}' "$c"; done | grep '/home/mobagel' || echo '(no bind mount under /home/mobagel)'
/typeai-demo-kc /home/mobagel/type-ai-platform-demo/type-ai-platform-infra/base/keycloak/realm-typeai.json->/opt/keycloak/data/import/realm-typeai.json
```

### systemd units

```console
$ grep -rno '/home/mobagel[^"'\'' :]*' /etc/systemd/system /lib/systemd/system 2>/dev/null || echo '(none)'
(none)
```

### Compose 與設定檔

```console
$ grep -rno '/home/mobagel[^"'\'' :]*' --include='*.yml' --include='*.yaml' --include='*.conf' --include='*.service' /home/mobagel /srv /etc 2>/dev/null | head -100 || echo '(none)'

```

### 環境檔位置（不含值）

```console
$ find /home/mobagel /srv -maxdepth 5 \( -name '.env' -o -name '.env.*' -o -name '*.env' \) 2>/dev/null | while read -r f; do printf '%s mode=%s keys=%s\n' "$f" "$(stat -c %a "$f")" "$(grep -cE '^[A-Za-z_][A-Za-z0-9_]*=' "$f" 2>/dev/null || echo 0)"; done
/home/mobagel/.claude/remote/plugins/92843486297a9df6/.env.example mode=600 keys=10
/home/mobagel/.claude/remote/plugins/20212d962a0535f8/.env.example mode=600 keys=10
/home/mobagel/.claude/remote/plugins/cad152b4001b96b9/.env.example mode=600 keys=10
/home/mobagel/.claude/remote/plugins/b1770cdfed1aa8ab/.env.example mode=600 keys=10
/home/mobagel/.claude/remote/plugins/7fa9e64992059352/.env.example mode=600 keys=10
/home/mobagel/.claude/remote/plugins/b48071e9f7bc4e5f/.env.example mode=600 keys=10
/home/mobagel/.claude/remote/plugins/7746bc41d1ed8716/.env.example mode=600 keys=10
/home/mobagel/.claude/remote/plugins/eb6bdb14f21afe02/.env.example mode=600 keys=10
/home/mobagel/.claude/remote/plugins/3677d3147a409de3/.env.example mode=600 keys=10
/home/mobagel/.claude/remote/plugins/aef5dd7bb8a2e8c0/.env.example mode=600 keys=10
/home/mobagel/.claude/remote/plugins/e4ba0b6a5276663b/.env.example mode=600 keys=10
/home/mobagel/.claude/remote/plugins/a58a2b080419e9e3/.env.example mode=600 keys=10
/home/mobagel/.claude/remote/plugins/3d954cc927284c09/.env.example mode=600 keys=10
/home/mobagel/.claude/remote/plugins/35a5f4f2e0be8453/.env.example mode=600 keys=10
/home/mobagel/.claude/remote/plugins/e90fb7358aad0aaa/.env.example mode=600 keys=10
/home/mobagel/.claude/remote/plugins/ccff40320cd37fcc/.env.example mode=600 keys=10
/home/mobagel/type-ai-platform-demo/type-ai-platform-frontend/.env.example mode=664 keys=4
/home/mobagel/type-ai-platform-demo/type-ai-platform-backend/.env.example mode=664 keys=37
/home/mobagel/type-ai-platform-demo/type-ai-platform-backend/.env mode=600 keys=12
```

### 環境檔鍵名（只有鍵名）

```console
$ find /home/mobagel /srv -maxdepth 5 \( -name '.env' -o -name '.env.*' -o -name '*.env' \) 2>/dev/null | while read -r f; do printf '\n%s:\n' "$f"; grep -oE '^[A-Za-z_][A-Za-z0-9_]*' "$f" 2>/dev/null | sed 's/^/  /'; done

/home/mobagel/.claude/remote/plugins/92843486297a9df6/.env.example:
  ANTHROPIC_API_KEY
  GITHUB_TOKEN
  ASTRAFLOW_API_KEY
  ASTRAFLOW_CN_API_KEY
  ATLAS_API_KEY
  GITHUB_USER
  DEFAULT_BASE_BRANCH
  SESSION_SCRIPT
  CONFIG_FILE
  ENABLE_VERBOSE_LOGGING

/home/mobagel/.claude/remote/plugins/20212d962a0535f8/.env.example:
  ANTHROPIC_API_KEY
  GITHUB_TOKEN
  ASTRAFLOW_API_KEY
  ASTRAFLOW_CN_API_KEY
  ATLAS_API_KEY
  GITHUB_USER
  DEFAULT_BASE_BRANCH
  SESSION_SCRIPT
  CONFIG_FILE
  ENABLE_VERBOSE_LOGGING

/home/mobagel/.claude/remote/plugins/cad152b4001b96b9/.env.example:
  ANTHROPIC_API_KEY
  GITHUB_TOKEN
  ASTRAFLOW_API_KEY
  ASTRAFLOW_CN_API_KEY
  ATLAS_API_KEY
  GITHUB_USER
  DEFAULT_BASE_BRANCH
  SESSION_SCRIPT
  CONFIG_FILE
  ENABLE_VERBOSE_LOGGING

/home/mobagel/.claude/remote/plugins/b1770cdfed1aa8ab/.env.example:
  ANTHROPIC_API_KEY
  GITHUB_TOKEN
  ASTRAFLOW_API_KEY
  ASTRAFLOW_CN_API_KEY
  ATLAS_API_KEY
  GITHUB_USER
  DEFAULT_BASE_BRANCH
  SESSION_SCRIPT
  CONFIG_FILE
  ENABLE_VERBOSE_LOGGING

/home/mobagel/.claude/remote/plugins/7fa9e64992059352/.env.example:
  ANTHROPIC_API_KEY
  GITHUB_TOKEN
  ASTRAFLOW_API_KEY
  ASTRAFLOW_CN_API_KEY
  ATLAS_API_KEY
  GITHUB_USER
  DEFAULT_BASE_BRANCH
  SESSION_SCRIPT
  CONFIG_FILE
  ENABLE_VERBOSE_LOGGING

/home/mobagel/.claude/remote/plugins/b48071e9f7bc4e5f/.env.example:
  ANTHROPIC_API_KEY
  GITHUB_TOKEN
  ASTRAFLOW_API_KEY
  ASTRAFLOW_CN_API_KEY
  ATLAS_API_KEY
  GITHUB_USER
  DEFAULT_BASE_BRANCH
  SESSION_SCRIPT
  CONFIG_FILE
  ENABLE_VERBOSE_LOGGING

/home/mobagel/.claude/remote/plugins/7746bc41d1ed8716/.env.example:
  ANTHROPIC_API_KEY
  GITHUB_TOKEN
  ASTRAFLOW_API_KEY
  ASTRAFLOW_CN_API_KEY
  ATLAS_API_KEY
  GITHUB_USER
  DEFAULT_BASE_BRANCH
  SESSION_SCRIPT
  CONFIG_FILE
  ENABLE_VERBOSE_LOGGING

/home/mobagel/.claude/remote/plugins/eb6bdb14f21afe02/.env.example:
  ANTHROPIC_API_KEY
  GITHUB_TOKEN
  ASTRAFLOW_API_KEY
  ASTRAFLOW_CN_API_KEY
  ATLAS_API_KEY
  GITHUB_USER
  DEFAULT_BASE_BRANCH
  SESSION_SCRIPT
  CONFIG_FILE
  ENABLE_VERBOSE_LOGGING

/home/mobagel/.claude/remote/plugins/3677d3147a409de3/.env.example:
  ANTHROPIC_API_KEY
  GITHUB_TOKEN
  ASTRAFLOW_API_KEY
  ASTRAFLOW_CN_API_KEY
  ATLAS_API_KEY
  GITHUB_USER
  DEFAULT_BASE_BRANCH
  SESSION_SCRIPT
  CONFIG_FILE
  ENABLE_VERBOSE_LOGGING

/home/mobagel/.claude/remote/plugins/aef5dd7bb8a2e8c0/.env.example:
  ANTHROPIC_API_KEY
  GITHUB_TOKEN
  ASTRAFLOW_API_KEY
  ASTRAFLOW_CN_API_KEY
  ATLAS_API_KEY
  GITHUB_USER
  DEFAULT_BASE_BRANCH
  SESSION_SCRIPT
  CONFIG_FILE
  ENABLE_VERBOSE_LOGGING

/home/mobagel/.claude/remote/plugins/e4ba0b6a5276663b/.env.example:
  ANTHROPIC_API_KEY
  GITHUB_TOKEN
  ASTRAFLOW_API_KEY
  ASTRAFLOW_CN_API_KEY
  ATLAS_API_KEY
  GITHUB_USER
  DEFAULT_BASE_BRANCH
  SESSION_SCRIPT
  CONFIG_FILE
  ENABLE_VERBOSE_LOGGING

/home/mobagel/.claude/remote/plugins/a58a2b080419e9e3/.env.example:
  ANTHROPIC_API_KEY
  GITHUB_TOKEN
  ASTRAFLOW_API_KEY
  ASTRAFLOW_CN_API_KEY
  ATLAS_API_KEY
  GITHUB_USER
  DEFAULT_BASE_BRANCH
  SESSION_SCRIPT
  CONFIG_FILE
  ENABLE_VERBOSE_LOGGING

/home/mobagel/.claude/remote/plugins/3d954cc927284c09/.env.example:
  ANTHROPIC_API_KEY
  GITHUB_TOKEN
  ASTRAFLOW_API_KEY
  ASTRAFLOW_CN_API_KEY
  ATLAS_API_KEY
  GITHUB_USER
  DEFAULT_BASE_BRANCH
  SESSION_SCRIPT
  CONFIG_FILE
  ENABLE_VERBOSE_LOGGING

/home/mobagel/.claude/remote/plugins/35a5f4f2e0be8453/.env.example:
  ANTHROPIC_API_KEY
  GITHUB_TOKEN
  ASTRAFLOW_API_KEY
  ASTRAFLOW_CN_API_KEY
  ATLAS_API_KEY
  GITHUB_USER
  DEFAULT_BASE_BRANCH
  SESSION_SCRIPT
  CONFIG_FILE
  ENABLE_VERBOSE_LOGGING

/home/mobagel/.claude/remote/plugins/e90fb7358aad0aaa/.env.example:
  ANTHROPIC_API_KEY
  GITHUB_TOKEN
  ASTRAFLOW_API_KEY
  ASTRAFLOW_CN_API_KEY
  ATLAS_API_KEY
  GITHUB_USER
  DEFAULT_BASE_BRANCH
  SESSION_SCRIPT
  CONFIG_FILE
  ENABLE_VERBOSE_LOGGING

/home/mobagel/.claude/remote/plugins/ccff40320cd37fcc/.env.example:
  ANTHROPIC_API_KEY
  GITHUB_TOKEN
  ASTRAFLOW_API_KEY
  ASTRAFLOW_CN_API_KEY
  ATLAS_API_KEY
  GITHUB_USER
  DEFAULT_BASE_BRANCH
  SESSION_SCRIPT
  CONFIG_FILE
  ENABLE_VERBOSE_LOGGING

/home/mobagel/type-ai-platform-demo/type-ai-platform-frontend/.env.example:
  VITE_OIDC_AUTHORITY
  VITE_OIDC_CLIENT_ID
  VITE_API_BASE_URL
  VITE_ENVIRONMENT_BANNER

/home/mobagel/type-ai-platform-demo/type-ai-platform-backend/.env.example:
  DATABASE_URL
  OIDC_ISSUER
  OIDC_AUDIENCE
  OIDC_JWKS_URL
  OIDC_JWKS_CACHE_SECONDS
  OIDC_LEEWAY_SECONDS
  SERVICE_TOKEN_SECRET
  SERVICE_TOKEN_ISSUER
  SERVICE_TOKEN_TTL_SECONDS
  LITELLM_BASE_URL
  LITELLM_MASTER_KEY
  AIDMS_BASE_URL
  AIDMS_EMAIL
  AIDMS_PASSWORD
  AIDMS_VERIFY_TLS
  AIDMS_CA_BUNDLE
  AIDMS_PROJECT_ID
  AIDMS_DOWNLOAD_READ_TIMEOUT_SECONDS
  AIDMS_DOWNLOAD_CONNECT_TIMEOUT_SECONDS
  AIDMS_DOWNLOAD_PACK_RATE_MB_PER_SECOND
  AIDMS_DOWNLOAD_RETRY_SECONDS
  AIDMS_DOWNLOAD_MAX_WAIT_SECONDS
  AIDMS_UPLOAD_MAX_CONCURRENT
  AIDMS_UPLOAD_CHUNK_TTL_SECONDS
  AIDMS_UPLOAD_IDLE_SECONDS
  AIDMS_UPLOAD_CONNECT_TIMEOUT_SECONDS
  AIDMS_UPLOAD_READ_TIMEOUT_SECONDS
  AIDMS_UPLOAD_DELETE_RETRY_SECONDS
  AIDMS_UPLOAD_DELETE_MAX_WAIT_SECONDS
  MODEL_CACHE_ENABLED
  MODEL_CACHE_DIR
  DLP_ENABLED
  CORS_ALLOW_ORIGINS
  DEMO_PASSWORD
  DEMO_ADMIN_USERNAME
  DEMO_MANAGER_USERNAME
  DEMO_GENERAL_USERNAME

/home/mobagel/type-ai-platform-demo/type-ai-platform-backend/.env:
  DATABASE_URL
  AIDMS_BASE_URL
  AIDMS_EMAIL
  AIDMS_PASSWORD
  AIDMS_VERIFY_TLS
  LOG_LEVEL
  DEMO_PASSWORD
  DEMO_ADMIN_USERNAME
  DEMO_MANAGER_USERNAME
  DEMO_GENERAL_USERNAME
  AIDMS_PROJECT_ID
  AIDMS_UPLOAD_PROJECT_IDS
```
