#!/bin/bash

RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
PLAIN="\033[0m"
WHITLE="\033[37m"
MAGENTA="\033[35m"
CYAN="\033[36m"
BLUE="\033[34m"
BOLD="\033[01m"

error() {
    echo -e "$RED$BOLD$1$PLAIN"
}

success() {
    echo -e "$GREEN$BOLD$1$PLAIN"
}

warning() {
    echo -e "$YELLOW$BOLD$1$PLAIN"
}

info() {
    echo -e "$PLAIN$BOLD$1$PLAIN"
}

REGEX=("debian" "ubuntu" "centos|red hat|kernel|oracle linux|alma|rocky" "'amazon linux'" "fedora")
RELEASE=("Debian" "Ubuntu" "CentOS" "CentOS" "Fedora")
PACKAGE_UPDATE=("apt-get update" "apt-get update" "yum -y update" "yum -y update" "yum -y update")
PACKAGE_INSTALL=("apt -y install" "apt -y install" "yum -y install" "yum -y install" "yum -y install")
PACKAGE_REMOVE=("apt -y remove" "apt -y remove" "yum -y remove" "yum -y remove" "yum -y remove")
PACKAGE_UNINSTALL=("apt -y autoremove" "apt -y autoremove" "yum -y autoremove" "yum -y autoremove" "yum -y autoremove")

[[ $EUID -ne 0 ]] && error "请切换至ROOT用户" && exit 1

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

[[ -z $SYSTEM ]] && error "操作系统类型不支持" && exit 1

##
workspace="/opt/tuic"
service="/lib/systemd/system/tuic.service"
fullchain="/root/cert/cert.crt"
private_key="/root/cert/private.key"

back2menu() {
    echo ""
    success "运行成功"
    read -rp "请输入“y”退出, 或按任意键回到主菜单：" back2menuInput
    case "$back2menuInput" in
        y) exit 1 ;;
        *) menu ;;
    esac
}

brefore_install() {
    info "更新并安装系统所需软件"
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

create_systemd() {
    if [[ -w "$service" ]]; then
        return
    fi
    cat > $service << EOF
    [Unit]
    Description=Delicately-TUICed high-performance proxy built on top of the QUIC protocol
    Documentation=https://github.com/EAimTY/tuic
    After=network.target

    [Service]
    User=root
    WorkingDirectory=${workspace}
    ExecStart=${workspace}/tuic-server -c config.json
    Restart=on-failure
    RestartPreventExitStatus=1
    RestartSec=5

    [Install]
    WantedBy=multi-user.target
EOF
    success "已添加${service}"
}

generate_random_password() {
    local length=$1
    local password=$(cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w $length | head -n 1)
    echo "$password"
}

find_unused_port() {
    local port
    while true; do
        port=$(shuf -i 1024-65535 -n 1)
        if [[ $(lsof -i:"${port}" | grep -i -c "listen") -eq 0 ]]; then
            echo "$port"
            break
        fi
    done
}


create_conf() {
    read -rp "请选择证书链位置(回车默认/root/cert/cert.crt)：" crt_input
    if [[ -n ${crt_input} ]]; then
        fullchain=crt_input
    fi

    read -rp "请选择证书私钥位置(回车默认/root/cert/private.key)：" key_input
    if [[ -n ${key_input} ]]; then
        private_key=key_input
    fi
    if [[ ! -r "${fullchain}" || ! -r "${private_key}" ]]; then
        error "证书不存在，请执行 [1]申请证书"
        back2menu
    fi
    
    chmod +x "$fullchain"
    chmod +x "$private_key"
    cat "${fullchain}" > "${workspace}/fullchain.pem"
    cat "${private_key}" > "${workspace}/private_key.pem"

    read -rp "请输入解析至本机的域名(www.example.com)：" domain_input
    if [[ -z ${domain_input} ]]; then
        error "未输入域名，请手动修改客户端配置中的[yourdomain]，否则无法正常使用"
        domain_input="yourdomain"
    fi
    read -rp "请为tuic分配端口：" port_input
    if [[ -z ${port_input} ]]; then
        error "未输入端口，默认分配随机端口"
        port_input=$(find_unused_port)
    fi
    str=$(openssl x509 -noout -fingerprint -sha256 -inform pem -in "${workspace}/fullchain.pem")
    fingerprint=$(echo "$str" | cut -d '=' -f 2)
    uuid=$(openssl rand -hex 16)
    password=$(generate_random_password 10)
    cat > config.json << EOF
    {
        "server": "[::]:${port_input}",
        "users": {
            "${uuid}": "${password}"
        },
        "certificate": "${workspace}/fullchain.pem",
        "private_key": "${workspace}/private_key.pem",
        "congestion_control": "bbr",
        "alpn": ["h3", "spdy/3.1"],
        "udp_relay_ipv6": false,
        "zero_rtt_handshake": false,
        "auth_timeout": "3s",
        "max_idle_time": "10s",
        "max_external_packet_size": 1500,
        "gc_interval": "3s",
        "gc_lifetime": "15s",
        "log_level": "WARN"
    }
EOF

    warning "将以下内容复制到Surge[Proxy]"
    success "TUIC_V5 = tuic, $(curl -s ipinfo.io/ip) , ${port_input}, server-cert-fingerprint=${fingerprint}, sni=${domain_input}, uuid=${uuid}, alpn=h3, password=${password}, version=5"
}

uninstall() {
    systemctl stop tuic && systemctl disable --now tuic.service && rm -rf ${workspace} && rm -rf ${service}
    error "已停止并卸载tuic"
}

run() {
    if [[ ! -e "$service" ]]; then
        error "tuic未安装" && back2menu
    fi
    systemctl enable --now tuic.service
    if systemctl status tuic | grep -q "active"; then
        success "tuic启动成功"
        return 0
    else
        error "tuic启动失败"
        warning "======== ERROR INFO ========="
        systemctl status tuic
        return 1
    fi
}

stop() {
    if [[ ! -e "$service" ]]; then
        error "tuic未安装" && back2menu
    fi
    systemctl stop tuic
}

install() {
    ARCH=$(uname -m)
    if [[ -d "${workspace}" ]]; then
        read -rp "是否重新安装tuic ? [y/n]" input
        case "$input" in
            y)  uninstall ;;
            *)  back2menu ;;
        esac
    fi
    mkdir ${workspace}
    cd ${workspace}
    info "当前工作目录：$(pwd)"
    info "下载tuic文件"
    URL="https://github.com/EAimTY/tuic/releases/download/tuic-server-1.0.0-beta0/tuic-server-1.0.0-beta0-$ARCH-unknown-linux-gnu"
    wget -N --no-check-certificate $URL -O tuic-server
    chmod +x tuic-server
    create_systemd
    create_conf
    run
}


menu() {
    echo ""
    echo -e " ${GREEN}1.${PLAIN} 申请证书"
    echo -e " ${GREEN}2.${PLAIN} 安装TUIC"
    echo -e " ${GREEN}3.${PLAIN} 运行TUIC"
    echo -e " ${GREEN}4.${PLAIN} 停止TUIC"
    echo -e " ${GREEN}5.${PLAIN} ${RED}卸载TUIC${PLAIN}"
    echo " -------------"
    echo -e " ${GREEN}0.${PLAIN} 退出脚本"
    echo ""
    read -rp "请选择: " NumberInput
    case "$NumberInput" in
        1) apply_cert ;;
        2) install ;;
        3) run ;;
        4) stop ;;
        5) uninstall ;;
        *) exit 1 ;;
    esac
}

menu
