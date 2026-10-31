# Debian SSH Manager

面向 Debian 13 及以上正式版本的中文交互脚本：修改 SSH 端口、修改 root 密码，或依次完成两项操作。需要 root、systemd、openssh-server、iproute2 和 util-linux。后续 Debian 版本仍需验证，不能保证未来所有 OpenSSH 配置均兼容。

## 一条命令运行

在服务器交互终端执行（先确保有云控制台/VNC 备用入口）：

```bash
curl -fL https://raw.githubusercontent.com/brian952700/debian-ssh-manager/main/ssh-manager.sh -o ssh-manager.sh && sudo bash ssh-manager.sh
```

已是 root 时可将 `sudo bash` 改为 `bash`。没有 curl 时先安装：`apt-get update && apt-get install -y curl`。建议先阅读下载的脚本。密码只在服务器的 `passwd` 提示中输入，无须提供给任何人。

## 修改端口

1. 先在云安全组和本机防火墙放行新 TCP 端口。
2. 菜单选择修改端口，首次选择“添加新端口并保留当前端口”。
3. 保持原连接，在另一终端通过新端口验证连接成功后，在原终端输入 `KEEP`。
4. 从新端口连接中再次运行脚本，选择“仅保留新端口”，验证成功并输入 `KEEP`。然后自行移除旧端口的防火墙放行规则。

脚本不自动修改 UFW、nftables 或云安全组。监听检查只能验证服务器本地监听，不能代替外部连接测试。若 root 登录受限制，可以使用原有获准登录的普通用户测试；密码修改本身不会开启 root 登录或密码认证。

## 配置与恢复

- 使用 `/etc/ssh/debian-ssh-manager.conf` 管理端口，在主配置开头加入 Include。
- 修改前备份到 `/etc/ssh/manager-backup.*`，运行 `sshd -t` 和 `sshd -T` 检查后 reload `ssh.service`。
- 未确认保存、可捕获的中断或配置/重载/监听检查失败时，恢复本次备份。断电、SIGKILL 等无法保证触发恢复；没有定时自动恢复机制。
- 不支持启用的 `ssh.socket`。服务参数覆盖、自定义多实例和第三方配置管理不属于支持范围。
- 若其他文件有显式 `Port` 或带旧端口的 `ListenAddress`，单端口模式会拒绝不完整切换并恢复；需先通过控制台整理这些配置。
- root 密码修改由 `passwd root` 完成，遵循 PAM 策略，成功后立即生效且无法自动回滚。两项操作不是原子事务。

通过控制台手动恢复（将目录替换为实际备份目录）：

```bash
backup=/etc/ssh/manager-backup.XXXXXXXX
cp -a "$backup/sshd_config" /etc/ssh/sshd_config
if [ -f "$backup/managed" ]; then
  cp -a "$backup/managed" /etc/ssh/debian-ssh-manager.conf
else
  rm -f /etc/ssh/debian-ssh-manager.conf
fi
/usr/sbin/sshd -t && systemctl reload ssh.service
```

## 验证范围

GitHub Actions 在 Debian 13 容器中执行 Bash 语法与 ShellCheck 检查。静态检查不等同于真实 VPS 的 SSH 切换测试；首次使用应在测试机验证。

参考：[Debian 13 sshd_config 手册](https://manpages.debian.org/trixie/openssh-server/sshd_config.5.en.html)、[sshd 检查参数](https://manpages.debian.org/trixie/openssh-server/sshd.8.en.html)。
