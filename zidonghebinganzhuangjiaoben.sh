#!/bin/bash

# 自动化定时备份+传送脚本，适用于主脚本中 curl <zidongbeifen.sh> 直接调用
# 注意：本脚本应独立运行，不含 case/33) 标签或 menu 结构

      clear
      send_stats "定时远程备份+传送"

      echo "检查系统类型并安装依赖..."

      # 检查 curl
      if ! command -v curl > /dev/null 2>&1; then
        echo "curl 未安装，尝试安装..."
        if grep -qi "ubuntu\|debian" /etc/os-release; then
          apt-get update && apt-get install -y curl
        elif grep -qi "centos\|redhat" /etc/os-release; then
          yum install -y curl
        fi
      else
        echo "curl 已安装，跳过"
      fi

# 检查 sshpass
if ! command -v sshpass > /dev/null 2>&1; then
    echo "sshpass 未安装，尝试安装..."
    if grep -qi "ubuntu\|debian" /etc/os-release; then
        apt-get update -y
        apt-get install -y sshpass
    elif grep -qi "centos\|redhat" /etc/os-release; then
        yum install -y epel-release
        yum install -y sshpass
    else
        echo "不支持的系统，请手动安装 sshpass"
        exit 1
    fi
else
    echo "sshpass 已安装，跳过"
fi
# -----------------------------
      # 检查 shc
      if ! command -v shc > /dev/null 2>&1; then
        echo "shc 未安装，尝试安装..."
        if grep -qi "ubuntu\|debian" /etc/os-release; then
          apt-get update && apt-get install -y shc
        elif grep -qi "centos\|redhat" /etc/os-release; then
          yum install -y shc
        fi
      else
        echo "shc 已安装，跳过"
      fi
# -----------------------------

if command -v shc > /dev/null 2>&1; then
    echo "shc 已安装，跳过"
    exit 0
fi

echo "shc 未安装，开始安装..."

# 安装依赖
if grep -qi "ubuntu\|debian" /etc/os-release; then
    apt update
    apt install -y gcc make wget tar
elif grep -qi "centos\|redhat" /etc/os-release; then
    yum install -y gcc make wget tar
else
    echo "不支持的系统，请手动安装 shc"
    exit 1
fi

# 下载源码
cd /tmp
wget -O shc-4.0.3.tar.gz https://github.com/neurobin/shc/archive/refs/tags/4.0.3.tar.gz

# 解压并编译
tar xf shc-4.0.3.tar.gz
cd shc-4.0.3/src
gcc -o shc shc.c

# 安装到系统路径
cp shc /usr/local/bin/

# 测试
if command -v shc > /dev/null 2>&1; then
    echo "shc 安装成功！"
else
    echo "shc 安装失败！"
    exit 1
fi

# -----------------------------
# 检查 rsync
# -----------------------------
if ! command -v rsync >/dev/null 2>&1; then
    echo "rsync 未安装，尝试安装..."
    if grep -qi "ubuntu\|debian" /etc/os-release; then
        apt-get update -y
        apt-get install -y rsync
    elif grep -qi "centos\|redhat" /etc/os-release; then
        yum install -y rsync
    else
        echo "不支持的系统，请手动安装 rsync"
        exit 1
    fi
else
    echo "rsync 已安装，跳过"
fi

# -----------------------------
# 检查 ssh
# -----------------------------
if ! command -v ssh >/dev/null 2>&1; then
    echo "ssh 未安装，尝试安装..."
    if grep -qi "ubuntu\|debian" /etc/os-release; then
        apt-get update -y
        apt-get install -y openssh-client
    elif grep -qi "centos\|redhat" /etc/os-release; then
        yum install -y openssh-clients
    else
        echo "不支持的系统，请手动安装 ssh"
        exit 1
    fi
else
    echo "ssh 已安装，跳过"
fi





      # 检查 upx
      if ! command -v upx > /dev/null 2>&1; then
        echo "upx 未安装，尝试安装..."
        wget https://github.com/upx/upx/releases/download/v4.0.1/upx-4.0.1-amd64_linux.tar.xz -O /tmp/upx.tar.xz
        tar xf /tmp/upx.tar.xz -C /tmp
        cp /tmp/upx-4.0.1-amd64_linux/upx /usr/local/bin/
        chmod +x /usr/local/bin/upx
        rm -rf /tmp/upx.tar.xz /tmp/upx-4.0.1-amd64_linux
        echo "upx 安装完成"
      else
        echo "upx 已安装，跳过"
      fi

      # 检查 node 和 npm
      if ! command -v node > /dev/null 2>&1 || ! command -v npm > /dev/null 2>&1; then
        echo "node 或 npm 未安装，尝试安装..."
        if grep -qi "ubuntu\|debian" /etc/os-release; then
          apt-get update && apt-get install -y nodejs npm
        elif grep -qi "centos\|redhat" /etc/os-release; then
          yum install -y nodejs npm
        fi
      else
        echo "node 和 npm 已安装，跳过"
      fi

      # 检查 bash-obfuscate
      if ! command -v bash-obfuscate > /dev/null 2>&1; then
        echo "bash-obfuscate 未安装，尝试安装..."
        npm install -g bash-obfuscate || echo "bash-obfuscate 安装失败，请手动安装"
      else
        echo "bash-obfuscate 已安装，跳过"
      fi


