#!/bin/bash

# 自动获取默认网卡
IFACE=$(ip route | grep default | awk '{print $5}')

# 获取本机IP
IP=$(ip -4 addr show dev "$IFACE" | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -n1)

# 获取子网掩码
MASK=$(ip -4 addr show dev "$IFACE" | grep -oP '(?<=inet\s)\d+(\.\d+){3}/\d+' | cut -d/ -f2 | head -n1)

# 转换CIDR到子网掩码
CIDR2MASK() {
    local i mask=""
    local full_octets=$(($1/8))
    local partial_octet=$(($1%8))

    for ((i=0; i<4; i++)); do
        if [ $i -lt $full_octets ]; then
            mask+="255"
        elif [ $i -eq $full_octets ]; then
            mask+=$((256 - 2**(8-$partial_octet)))
        else
            mask+="0"
        fi
        [ $i -lt 3 ] && mask+="."
    done
    echo $mask
}

MASK=$(CIDR2MASK "$MASK")

# 获取默认网关
GW=$(ip route | grep default | awk '{print $3}')

# 拼接参数
PARAMS="$IP,$MASK,$GW"

# 打印确认信息
echo "======================"
echo "检测到的网络参数："
echo "IP: $IP"
echo "子网掩码: $MASK"
echo "网关: $GW"
echo "最终参数: $PARAMS"
echo "======================"
echo "账户名：Administrator"
echo "初始密码：1keydd"
echo "登陆后请务必修改密码！"
echo "======================"
read -p "按回车键确认安装，或 Ctrl+C 取消..."

# 执行命令
wget -qO- inst.sh | bash -s - -n "$PARAMS" -t https://file.1323123.xyz/dd/windows/1keydd/win10ltsc_password_1keydd.gz
