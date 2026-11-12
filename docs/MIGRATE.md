# Muse2API 服务器迁移

这套流程用于把当前运行中的 Muse2API 迁移到新的 Ubuntu VPS。备份包包含代码、Git 元数据、账号 Cookie、任务记录、`.env`、systemd 服务和网络监控配置。`data/media` 如果是外挂磁盘软连接，只会备份软连接本身，不会自动复制外挂磁盘里的全部媒体文件。

备份包包含敏感信息，尤其是 `data/accounts.json`、`.env` 和可能的媒体文件。只通过安全的服务器间传输，不要上传到公开网盘或提交到 Git。

## 一、旧服务器打包

先确认旧服务器当前版本正常，然后执行：

```bash
cd /home/muse2api
sudo bash deploy/backup-muse2api.sh
```

默认生成：

```text
/var/backups/muse2api/muse2api-backup-时间.tar.gz
/var/backups/muse2api/muse2api-backup-时间.tar.gz.sha256
```

如果媒体文件很大、可以在新服务器重新生成，可排除媒体：

```bash
sudo bash deploy/backup-muse2api.sh --no-media
```

如果媒体目录使用外挂盘软连接，建议另外备份外挂盘内容：

```bash
sudo tar -C /mnt/mydisk -czf /var/backups/muse2api/muse2api-media-时间.tar.gz muse2api-media
```

浏览器 profile 通常不需要迁移，因为账号 Cookie 已保存在 `data/accounts.json`，服务启动时会重新注入。只有确认需要保留浏览器状态时才执行：

```bash
sudo bash deploy/backup-muse2api.sh \
  --include-profiles \
  --profiles-dir /root/muse2api-profiles
```

查看备份包：

```bash
sudo ls -lh /var/backups/muse2api/
sudo sha256sum -c /var/backups/muse2api/*.sha256
```

## 二、传到新 VPS

建议使用 `scp`，示例：

```bash
scp root@旧服务器IP:/var/backups/muse2api/muse2api-backup-时间.tar.gz /root/
scp root@旧服务器IP:/var/backups/muse2api/muse2api-backup-时间.tar.gz.sha256 /root/
```

## 三、新 VPS 准备环境

以 Ubuntu 24.04 为例：

```bash
sudo apt-get update
sudo apt-get install -y \
  ca-certificates curl dnsutils python3 python3-pip python3-venv \
  chromium fonts-wqy-zenhei
```

配置 DNS。宝塔环境可以在“Linux 工具箱 → DNS 设置”填写：

```text
主要 DNS：1.1.1.1
备用 DNS：8.8.8.8
```

确认：

```bash
resolvectl status
```

新 VPS 需要先挂载媒体盘，并保持目录一致：

```text
/mnt/mydisk/muse2api-media
```

更新脚本会在每次拉取代码后自动保持：

```text
/home/muse2api/data/media -> /mnt/mydisk/muse2api-media
```

如果媒体盘未挂载，更新脚本会主动停止，避免误把媒体写入系统盘。

如果旧的 `/home/muse2api/data/media` 里已经有数据，先执行一次迁移：

```bash
sudo apt-get install -y rsync
cd /home/muse2api
sudo bash deploy/migrate-media-to-disk.sh
```

脚本会先复制并校验数据，然后把旧目录改名为 `media.pre-migration-时间`，最后创建软连接。确认服务正常后，再手动删除旧目录。

## 四、恢复应用

恢复脚本包含在备份包的 `app/deploy/restore-muse2api.sh` 中。先从备份包取出脚本：

```bash
mkdir -p /tmp/muse2api-restore
tar -xzf /root/muse2api-backup-时间.tar.gz \
  -C /tmp/muse2api-restore app/deploy/restore-muse2api.sh
```

执行恢复：

```bash
sudo bash /tmp/muse2api-restore/app/deploy/restore-muse2api.sh \
  /root/muse2api-backup-时间.tar.gz
```

如果目标目录已经存在，脚本默认拒绝覆盖。确认要迁移时使用：

```bash
sudo bash /tmp/muse2api-restore/app/deploy/restore-muse2api.sh \
  /root/muse2api-backup-时间.tar.gz --force
```

`--force` 不会直接删除旧目录，而是把它改名为 `/home/muse2api.pre-restore-时间`。

恢复脚本会自动：

1. 恢复代码和 `data/`；
2. 恢复 `.env`、账号 Cookie、任务记录和 Git 仓库；
3. 如备份时指定 `--include-profiles`，恢复浏览器 profile；
4. 创建 `/home/muse2api/.venv`；
5. 安装 Python 依赖；
6. 恢复 systemd 服务；
7. 启动 `muse2api-python.service`；
8. 启用网络/DNS 定时检查；
9. 检查 `http://127.0.0.1:18610/healthz`。

恢复后配置以后使用的更新脚本：

```bash
sudo cp /home/muse2api/deploy/update_muse2api.sh.example /root/update_muse2api.sh
sudo chmod 700 /root/update_muse2api.sh
```

以后更新：

```bash
sudo bash /root/update_muse2api.sh
```

## 五、验证

```bash
sudo systemctl status muse2api-python.service --no-pager
curl -fsS http://127.0.0.1:18610/healthz
sudo systemctl status muse2api-connectivity-check.timer --no-pager
sudo journalctl -u muse2api-python.service -n 100 --no-pager -o cat
sudo journalctl -u muse2api-connectivity-check.service -n 50 --no-pager
```

验证 Muse 网络入口：

```bash
curl -4 -sS -o /dev/null -w '%{http_code}\n' \
  --connect-timeout 5 --max-time 15 \
  -H 'Connection: Upgrade' \
  -H 'Upgrade: websocket' \
  -H 'Sec-WebSocket-Version: 13' \
  -H 'Sec-WebSocket-Key: SGVsbG9XU0tleQ==' \
  https://hatch.metaaivm.com/v1/noise
```

返回 `401` 也表示网络、TCP 和 TLS 已经连通；超时才表示网络入口仍有问题。

## 六、宝塔/Nginx 反向代理

如果新 VPS 使用宝塔反向代理，重新配置到 `http://127.0.0.1:18610`，并保留：

```nginx
proxy_read_timeout 600s;
proxy_send_timeout 600s;
proxy_buffering off;
client_max_body_size 200M;
```

域名、SSL 证书、宝塔站点配置不包含在 Muse2API 备份包中，需要在新 VPS 单独配置。

## 七、迁移完成后的安全检查

```bash
sudo chmod 600 /home/muse2api/.env /home/muse2api/data/accounts.json
sudo systemctl is-enabled muse2api-python.service
sudo systemctl is-enabled muse2api-connectivity-check.timer
```

确认新 VPS 工作正常后，再下线旧 VPS。不要在确认前删除旧服务器或旧备份包。
