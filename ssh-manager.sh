#!/usr/bin/env bash
set -Eeuo pipefail
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
umask 077
die() { printf '错误：%s\n' "$*" >&2; exit 1; }
[[ $EUID == 0 ]] || die '请使用 sudo bash ssh-manager.sh 或以 root 运行。'
[[ -r /etc/os-release ]] || die '无法识别系统。'
. /etc/os-release
[[ ${ID:-} == debian && ${VERSION_ID:-} =~ ^[0-9]+$ ]] || die '仅支持正式版本 Debian 13 及以上。'
(( VERSION_ID >= 13 )) || die '需要 Debian 13 或以上。'
[[ -t 0 && -t 1 ]] || die '需要交互终端；请先下载脚本，再运行。'
command -v flock >/dev/null || die '缺少 flock（util-linux）。'
exec 9>/run/debian-ssh-manager.lock
flock -n 9 || die '已有脚本实例运行。'
config=/etc/ssh/sshd_config
managed=/etc/ssh/debian-ssh-manager.conf
backup=''
rollback() {
  [[ -n $backup ]] || return 0
  cp -a "$backup/sshd_config" "$config"
  if [[ -e $backup/managed ]]; then cp -a "$backup/managed" "$managed"; else rm -f "$managed"; fi
  /usr/sbin/sshd -t && systemctl reload ssh.service
  printf '已恢复 SSH 配置，备份目录：%s\n' "$backup"
  backup=''
}
failed() { local rc=$?; trap - ERR HUP INT TERM; rollback || printf '自动恢复失败，请通过控制台恢复备份。\n' >&2; exit "$rc"; }
trap failed ERR
trap 'exit 130' INT
trap 'exit 143' HUP TERM
trap 'if [[ -n $backup ]]; then rollback; fi' EXIT
change_port() {
  local port answer mode effective old_ports candidate p
  command -v ss >/dev/null || die '缺少 ss（iproute2）。'
  [[ -x /usr/sbin/sshd && -f $config ]] || die '请先安装 openssh-server。'
  systemctl is-active --quiet ssh.service || die 'ssh.service 未运行。'
  if systemctl is-active --quiet ssh.socket || systemctl is-enabled --quiet ssh.socket 2>/dev/null; then
    die '检测到 ssh.socket；请先通过控制台切换至 ssh.service，再运行。'
  fi
  /usr/sbin/sshd -t
  effective=$(/usr/sbin/sshd -T)
  old_ports=$(awk '$1=="port" {print $2}' <<< "$effective")
  printf '当前配置端口：%s\n' "${old_ports//$'\n'/ }"
  read -r -p '新 SSH 端口（1-65535）：' port
  [[ $port =~ ^[0-9]{1,5}$ ]] || die '端口必须是数字。'
  port=$((10#$port))
  (( port >= 1 && port <= 65535 )) || die '端口范围为 1-65535。'
  if ! grep -qx "$port" <<< "$old_ports" && [[ -n $(ss -H -ltn "sport = :$port") ]]; then die '该端口已被占用。'; fi
  printf '1) 添加新端口并保留当前端口（首次切换推荐）\n2) 仅保留新端口（应先用新端口登录后执行）\n'
  read -r -p '选择 [1]：' mode
  mode=${mode:-1}
  [[ $mode == 1 || $mode == 2 ]] || die '无效选择。'
  printf '请先在云安全组及本机防火墙放行 TCP %s。脚本不修改防火墙。\n' "$port"
  read -r -p '确认已放行，输入 YES：' answer
  [[ $answer == YES ]] || return 0
  backup=$(mktemp -d /etc/ssh/manager-backup.XXXXXXXX)
  cp -a "$config" "$backup/sshd_config"
  [[ ! -e $managed ]] || cp -a "$managed" "$backup/managed"
  # A private include at the very beginning is independent of vendor Include ordering.
  candidate=$(mktemp /etc/ssh/manager-main.XXXXXXXX)
  { printf 'Include %s\n' "$managed"; sed '\|^Include /etc/ssh/debian-ssh-manager.conf$|d' "$config"; } > "$candidate"
  cat "$candidate" > "$config"
  rm -f "$candidate"
  { printf 'Port %s\n' "$port"; if [[ $mode == 1 ]]; then for p in $old_ports; do [[ $p == "$port" ]] || printf 'Port %s\n' "$p"; done; fi; } > "$managed"
  chmod 600 "$managed"
  /usr/sbin/sshd -t
  effective=$(/usr/sbin/sshd -T)
  # Existing Port/ListenAddress directives may add listeners; never claim replacement in that case.
  if [[ $mode == 2 ]] && awk -v p="$port" '$1=="port" && $2!=p {bad=1} END {exit !bad}' <<< "$effective"; then
    die '其他配置文件仍声明旧 Port；已取消操作并恢复。请先整理自定义 Port 配置。'
  fi
  if awk -v p="$port" '$1=="listenaddress" && $2 !~ (":" p "$") {bad=1} END {exit !bad}' <<< "$effective"; then
    [[ $mode == 1 ]] || die '存在绑定到旧端口的 ListenAddress；已取消操作并恢复。'
  fi
  systemctl reload ssh.service
  sleep 1
  [[ -n $(ss -H -ltn "sport = :$port") ]] || die '新端口未监听，正在恢复。'
  printf '新端口已监听。请保留本窗口，用另一个终端验证：ssh -p %s root@服务器IP\n' "$port"
  read -r -p '确认新连接成功后输入 KEEP；其他输入或中断均恢复配置：' answer
  if [[ $answer == KEEP ]]; then
    printf '已保存。备份：%s\n' "$backup"
    backup=''
  else
    rollback
  fi
}
change_password() {
  printf '通过系统 passwd 修改 root 密码；输入不回显，密码不会进入脚本参数或文件。\n'
  passwd root
  printf 'root 密码已修改。密码修改不支持自动回滚，也不会开启 SSH root/密码登录权限。\n'
}
printf 'Debian SSH 管理\n1) 修改 SSH 端口\n2) 修改 root 密码\n3) 依次修改端口和 root 密码\n0) 退出\n'
read -r -p '请选择：' action
case $action in
  1) change_port ;;
  2) change_password ;;
  3) change_port; change_password ;;
  0) exit 0 ;;
  *) die '无效选择。' ;;
esac
