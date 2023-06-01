#!/bin/bash

RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
PLAIN='\033[0m'

red() {
    echo -e "\033[31m\033[01m$1\033[0m"
}

green() {
    echo -e "\033[32m\033[01m$1\033[0m"
}

yellow() {
    echo -e "\033[33m\033[01m$1\033[0m"
}

plain() {
    echo -e "\033[0m\033[01m$1\033[0m"
}

REGEX=("debian" "ubuntu" "centos|red hat|kernel|oracle linux|alma|rocky" "'amazon linux'" "fedora")
RELEASE=("Debian" "Ubuntu" "CentOS" "CentOS" "Fedora")
PACKAGE_UPDATE=("apt-get update" "apt-get update" "yum -y update" "yum -y update" "yum -y update")
PACKAGE_INSTALL=("apt -y install" "apt -y install" "yum -y install" "yum -y install" "yum -y install")
PACKAGE_REMOVE=("apt -y remove" "apt -y remove" "yum -y remove" "yum -y remove" "yum -y remove")
PACKAGE_UNINSTALL=("apt -y autoremove" "apt -y autoremove" "yum -y autoremove" "yum -y autoremove" "yum -y autoremove")

[[ $EUID -ne 0 ]] && red "请切换至ROOT用户" && exit 1

CMD=("$(grep -i pretty_name /etc/os-release 2>/dev/null | cut -d \" -f2)" "$(hostnamectl 2>/dev/null | grep -i system | cut -d : -f2)" "$(lsb_release -sd 2>/dev/null)" "$(grep -i description /etc/lsb-release 2>/dev/null | cut -d \" -f2)" "$(grep . /etc/redhat-release 2>/dev/null)" "$(grep . /etc/issue 2>/dev/null | cut -d \\ -f1 | sed '/^[ ]*$/d')")

for i in "${CMD[@]}"; do
    SYS="$i"
    if [[ -n $SYS ]]; then
        break
    fi
done

for ((int = 0; int < ${#REGEX[@]}; int++)); do
    if [[ $(echo "$SYS" | tr '[:upper:]' '[:lower:]') =~ ${REGEX[int]} ]]; then
        SYSTEM="${RELEASE[int]}"
        if [[ -n $SYSTEM ]]; then
            break
        fi
    fi
done

[[ -z $SYSTEM ]] && red "你所在的操作系统不支持该脚本" && exit 1

back2menu() {
    echo ""
    green "所选命令操作执行完成"
    read -rp "请输入“y”退出, 或按任意键回到主菜单：" back2menuInput
    case "$back2menuInput" in
        y) exit 1 ;;
        *) menu ;;
    esac
}

brefore_install() {
    green "更新并安装系统所需软件"
    if [[ ! $SYSTEM == "CentOS" ]]; then
        ${PACKAGE_UPDATE[int]}
    fi
    ${PACKAGE_INSTALL[int]} curl wget sudo socat openssl
    if [[ $SYSTEM == "CentOS" ]]; then
        ${PACKAGE_INSTALL[int]} cronie
        systemctl start crond
        systemctl enable crond
    else
        ${PACKAGE_INSTALL[int]} cron
        systemctl start cron
        systemctl enable cron
    fi
}

apply_cert() {
    wget -N --no-check-certificate https://raw.githubusercontent.com/CCCOrz/auto-acme/main/main.sh && bash main.sh
}

install() {
    ARCH=$(uname -m)
    mkdir /opt/tuic && cd /opt/tuic
    green "下载tuic文件"
    URL="https://github.com/EAimTY/tuic/releases/download/tuic-server-1.0.0-beta0/tuic-server-1.0.0-beta0-$ARCH-unknown-linux-gnu"
    wget -N --no-check-certificate -O tuic-server
    chmod +x tuic-server
    cat << EOF >> config.json
    {
        "server": "[::]:52408",
        "users": {
            "8e21e704-9ac8-4fb8-bef1-6c9d7d7e390b": "RnJ5BfJ3"
        },
        "certificate": "/opt/tuic/fullchain.pem",
        "private_key": "/opt/tuic/privkey.pem",
        "congestion_control": "bbr",
        "alpn": ["h3", "spdy/3.1"],
        "udp_relay_ipv6": false,
        "zero_rtt_handshake": false,
        "auth_timeout": "3s",
        "max_idle_time": "10s",
        "max_external_packet_size": 1500,
        "gc_interval": "3s",
        "gc_lifetime": "15s",
        "log_level": "warn"
    }
    EOF
    cat /root/cert/cert.crt > /opt/tuic/fullchain.pem
    cat /root/cert/private.key > /opt/tuic/privkey.pem
    ./tuic-server -c config.json
    green "已安装tuic"
    openssl x509 -noout -fingerprint -sha256 -inform pem -in /opt/tuic/fullchain.pem
    green "已锁定证书"
    green "TUIC V5 = tuic, $(curl -s ipinfo.io/ip) , 52408, skip-cert-verify=true, sni=your.com, uuid=8e21e704-9ac8-4fb8-bef1-6c9d7d7e390b, alpn=h3, password=RnJ5BfJ3, version=5"
}

uninstall() {
    rm -rf /opt/tuic
    green "已卸载tuic"
}

menu() {
    echo ""
    echo -e " ${GREEN}1.${PLAIN} 申请证书"
    echo -e " ${GREEN}2.${PLAIN} 安装并运行TUIC"
    echo -e " ${GREEN}3.${PLAIN} ${RED}卸载TUIC${PLAIN}"
    echo " -------------"
    echo -e " ${GREEN}0.${PLAIN} 退出脚本"
    echo ""
    read -rp "请输入选项执行: " NumberInput
    case "$NumberInput" in
        1) apply_cert ;;
        2) install ;;
        3) uninstall ;;
        *) exit 1 ;;
    esac
}

menu
