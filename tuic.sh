#!/bin/bash
sleep 1
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
    ${PACKAGE_INSTALL[int]} curl wget sudo socat openssl certbot cronie
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

check_80(){
    # Fork from https://github.com/Misaka-blog/acme-script/blob/main/acme.sh
    # thanks
    if [[ -z $(type -P lsof) ]]; then
        if [[ ! $SYSTEM == "CentOS" ]]; then
            ${PACKAGE_UPDATE[int]}
        fi
        ${PACKAGE_INSTALL[int]} lsof
    fi
    
    warning "正在检测80端口是否占用..."
    sleep 1
    
    if [[  $(lsof -i:"80" | grep -i -c "listen") -eq 0 ]]; then
        success "检测到目前80端口未被占用"
        sleep 1
    else
        error "检测到目前80端口被其他程序被占用，以下为占用程序信息"
        lsof -i:"80"
        read -rp "如需结束占用进程请按Y，按其他键则退出 [Y/N]: " yn
        if [[ $yn =~ "Y"|"y" ]]; then
            lsof -i:"80" | awk '{print $2}' | grep -v "PID" | xargs kill -9
            sleep 1
        else
            exit 1
        fi
    fi
}

cert_update() {
    cat > /etc/letsencrypt/renewal-hooks/post/tuic.sh << EOF
    #!/bin/bash
    cat /etc/letsencrypt/live/$1*/fullchain.pem > ${workspace}/fullchain.pem
    cat /etc/letsencrypt/live/$1*/privkey.pem > ${workspace}/private_key.pem
    systemctl restart tuic.service
EOF
    warning "测试证书自动续费..."
    chmod +x /etc/letsencrypt/renewal-hooks/post/tuic.sh
    bash /etc/letsencrypt/renewal-hooks/post/tuic.sh
    if crontab -l | grep -q "$1"; then
        warning "已存在$1的证书自动续期任务"
    else
        crontab -l > conf_temp && echo "0 0 * */2 * certbot renew --cert-name $1 --dry-run" >> conf_temp && crontab conf_temp && rm -f conf_temp
        warning "已添加$1的证书自动续期任务"
    fi
}

apply_cert() {
    warning "正在为您申请证书，您稍等..."
    certbot certonly \
    --standalone \
    --agree-tos \
    --no-eff-email \
    --email $1 \
    -d $2
    exit_cert=$(cat /etc/letsencrypt/live/$2*/fullchain.pem | grep -i -c "cert")
    exit_key=$(cat /etc/letsencrypt/live/$2*/privkey.pem | grep -i -c "key")
    if [[ ${exit_cert} -eq 0 || ${exit_key} -eq 0 ]]; then
        error "证书申请失败" && exit 1
    fi
}

check_cert() {
    exit_cert=$(cat /etc/letsencrypt/live/$2*/fullchain.pem | grep -i -c "cert")
    exit_key=$(cat /etc/letsencrypt/live/$2*/privkey.pem | grep -i -c "key")
    if [[ ${exit_cert} -ne 0 || ${exit_key} -ne 0 ]]; then
        read -rp "是否撤销已有证书？(y/[n])：" del_cert
        if [[ ${del_cert} == [yY] ]]; then
            warning "正在撤销$2的证书..."
            certbot revoke --cert-path /etc/letsencrypt/live/$2*/cert.pem
            apply_cert $1 $2
        else 
            info "使用已有证书"
        fi
    else
        apply_cert $1 $2
    fi
    cert_update $2
}

create_systemd() {
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
    systemctl daemon-reload
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
    read -rp "请输入注册邮箱(必填): " email_input
    if [[ -z $email_input ]]; then
        error "邮箱不能为空" && exit 1
    fi
    read -rp "请输入域名(必填)：" domain_input
    if [[ -z ${domain_input} ]]; then
        error "域名不能为空" && exit 1
    fi
    check_80
    check_cert $email_input $domain_input
    read -rp "请为tuic分配端口(留空随机分配)：" port_input
    if [[ -z ${port_input} ]]; then
        port_input=$(find_unused_port)
        warning "使用随机端口 : $port_input"
    fi
    
    uuid=$(cat /proc/sys/kernel/random/uuid)
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
    read -rp "是否启用证书指纹？(y/[n])：" not_fingerprint
    if [[ ${not_fingerprint} == [yY] ]]; then
        str=$(openssl x509 -noout -fingerprint -sha256 -inform pem -in "${workspace}/fullchain.pem")
        fingerprint=$(echo "$str" | cut -d '=' -f 2)
        if [[ -n ${fingerprint} ]]; then
            warning "已添加证书指纹"
            echo -e "TUIC_V5 = tuic, $(curl -s ipinfo.io/ip) , ${port_input}, server-cert-fingerprint-sha256=${fingerprint}, sni=${domain_input}, uuid=${uuid}, alpn=h3, password=${password}, version=5" > client.txt
        else 
            error "证书指纹生成失败，请检查证书有效性" && exit 1
        fi
    else
        echo -e "TUIC_V5 = tuic, $(curl -s ipinfo.io/ip) , ${port_input}, skip-cert-verify=true, sni=${domain_input}, uuid=${uuid}, alpn=h3, password=${password}, version=5" > client.txt
    fi
}

uninstall() {
    if [[ ! -e "$service" ]]; then
        error "tuic未安装" && back2menu
    fi
    systemctl stop tuic && \
    systemctl disable --now tuic.service && \
    rm -rf ${workspace} && rm -rf ${service} 
    error "已停止并卸载tuic"
}

run() {
    if [[ ! -e "$service" ]]; then
        error "tuic未安装" && back2menu
    fi
    systemctl enable --now tuic.service
    if systemctl status tuic | grep -q "active"; then
        success "tuic启动成功"
        warning "[Proxy] 配置"
        info "----------------------"
        cat "${workspace}/client.txt"
        info "----------------------"
        warning "客户端配置目录：${workspace}/client.txt"
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
        error "tuic未安装" 
    else
        systemctl stop tuic
        info "tuic已停止"
    fi
    back2menu
}

install() {
    ARCH=$(uname -m)
    if [[ -d "${workspace}" ]]; then
        read -rp "是否重新安装tuic？(y/[n])" input
        case "$input" in
            y)  uninstall ;;
            *)  back2menu ;;
        esac
    else
        brefore_install
    fi
    mkdir ${workspace}
    cd ${workspace}
    info "当前工作目录：$(pwd)"
    info "下载tuic文件"
    URL="https://github.com/EAimTY/tuic/releases/download/tuic-server-1.0.0-rc0/tuic-server-1.0.0-rc0-$ARCH-unknown-linux-gnu"
    wget -N --no-check-certificate $URL -O tuic-server
    chmod +x tuic-server
    create_systemd
    create_conf
    run
}


menu() {
    echo ""
    echo -e " ${GREEN}1.${PLAIN} 安装TUIC"
    echo -e " ${GREEN}2.${PLAIN} 运行TUIC"
    echo -e " ${GREEN}3.${PLAIN} 停止TUIC"
    echo -e " ${GREEN}4.${PLAIN} ${RED}卸载TUIC${PLAIN}"
    echo " -------------"
    echo -e " ${GREEN}0.${PLAIN} 退出脚本"
    echo ""
    read -rp "请选择: " NumberInput
    case "$NumberInput" in
        1) install ;;
        2) run ;;
        3) stop ;;
        4) uninstall ;;
        *) exit 1 ;;
    esac
}

menu
