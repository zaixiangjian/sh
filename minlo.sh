#!/bin/bash
# =====================================================
# 一键安装 MinIO 客户端 mc + 用户管理脚本
# 功能：
# 1. 安装 mc
# 2. 添加 S3 用户
# 3. 赋予所有访问权限
# 4. 创建子密钥
# 5. 重置子密钥
# =====================================================

set -e

# =======================
# 函数定义
# =======================

install_mc() {
    echo "==> 安装 MinIO 客户端 mc..."
    if ! command -v mc &>/dev/null; then
        wget https://dl.min.io/client/mc/release/linux-amd64/mc -O /usr/local/bin/mc
        chmod +x /usr/local/bin/mc
        echo "mc 安装完成：$(mc --version)"
    else
        echo "mc 已安装：$(mc --version)"
    fi
}

add_s3_user() {
    read -p "请输入 MinIO Server Endpoint (例如 http://127.0.0.1:9000): " MINIO_ENDPOINT
    read -p "请输入 Root 用户名: " MINIO_ROOT_USER
    read -s -p "请输入 Root 密码: " MINIO_ROOT_PASSWORD
    echo
    read -p "请输入新 S3 用户名: " NEW_USER

    # 选择密码方式
    echo "请选择密码方式："
    echo "1) 自动生成 20 位随机密码"
    echo "2) 手动输入密码"
    read -p "请输入选项 [1/2]: " PASS_CHOICE

    if [[ "$PASS_CHOICE" == "2" ]]; then
        read -s -p "请输入密码: " NEW_USER_PASS
        echo
    else
        NEW_USER_PASS=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 20)
    fi

    # 设置 mc alias
    mc alias set myminio $MINIO_ENDPOINT $MINIO_ROOT_USER $MINIO_ROOT_PASSWORD

    # 添加用户
    echo "==> 添加用户 $NEW_USER ..."
    mc admin user add myminio $NEW_USER $NEW_USER_PASS

    # 赋予全局权限
    echo "==> 赋予 $NEW_USER 全局 readwrite 权限 ..."
    mc admin policy attach myminio readwrite --user $NEW_USER

    echo "S3 用户 $NEW_USER 创建完成，密码: $NEW_USER_PASS"
}

create_subkey() {
    read -p "请输入 S3 用户名: " USERNAME
    echo "==> 创建子密钥 (Service Account) ..."
    MC_CHILD_JSON=$(mc admin user svcacct add myminio $USERNAME)
    echo "子密钥信息："
    echo "$MC_CHILD_JSON" | grep "Access Key\|Secret Key"
}

reset_subkey() {
    read -p "请输入 S3 用户名: " USERNAME

    # 列出该用户所有子密钥
    echo "==> 当前 $USERNAME 的子密钥列表："
    mc admin user svcacct list myminio $USERNAME | grep "Access Key"

    # 提示输入要重置的 Access Key
    read -p "请输入要重置的 Access Key: " OLD_KEY

    # 执行重置
    MC_NEW_CHILD=$(mc admin user svcacct reset myminio $OLD_KEY)
    echo "重置后的子密钥信息："
    echo "$MC_NEW_CHILD" | grep "Access Key\|Secret Key"
}

# =======================
# 主菜单循环
# =======================
while true; do
    echo "=============================="
    echo "一键安装 MinIO 客户端 mc + 用户管理"
    echo "功能列表："
    echo "1) 安装 mc"
    echo "2) 添加 S3 用户"
    echo "3) 创建子密钥 (Service Account)"
    echo "4) 重置子密钥"
    echo "5) 退出"
    echo "=============================="

    read -p "请输入选项 [1-5]: " choice
    case $choice in
        1) install_mc ;;
        2) add_s3_user ;;
        3) create_subkey ;;
        4) reset_subkey ;;
        5) echo "退出脚本"; exit 0 ;;
        *) echo "无效选项，请输入 1-5" ;;
    esac
done
