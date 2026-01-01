#!/bin/bash
# =====================================================
# 一键安装 MinIO 客户端 mc + S3 用户/ API 管理脚本
# 功能：
# 1. 安装 mc
# 2. 添加 S3 用户
# 3. 创建 API (随机生成 Access Key + Secret Key)
# 4. 赋予访问权限
# 5. 重置 API
# 0. 退出
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
    read -p "请输入地址 Endpoint 默认(http://127.0.0.1:9000): " MINIO_ENDPOINT
    MINIO_ENDPOINT=${MINIO_ENDPOINT:-http://127.0.0.1:9000}
    echo "使用 MinIO Endpoint: $MINIO_ENDPOINT"
    read -p "请输入 Root 用户名: " MINIO_ROOT_USER
    read -s -p "请输入 Root 密码: " MINIO_ROOT_PASSWORD
    echo
    read -p "请输入新 S3 用户名: " NEW_USER

    # 设置 mc alias
    mc alias set myminio $MINIO_ENDPOINT $MINIO_ROOT_USER $MINIO_ROOT_PASSWORD

    # 自动生成 20 位随机密码
    NEW_USER_PASS=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 20)

    # 添加用户
    echo "==> 添加用户 $NEW_USER ..."
    mc admin user add myminio $NEW_USER $NEW_USER_PASS

    echo "S3 用户 $NEW_USER 创建完成，密码: $NEW_USER_PASS"
}

reset_api() {
    read -p "请输入 S3 用户名: " USERNAME

    # 列出用户现有子密钥
    echo "==> 当前 $USERNAME 的 API 列表："
    API_LIST=$(mc admin user svcacct list myminio $USERNAME | grep "Access Key" | awk '{print $1}')
    
    if [[ -z "$API_LIST" ]]; then
        echo "(该用户还没有 API，先创建一个)"
        # 自动生成一个新 API
        NEW_ACCESS_KEY=$(tr -dc 'A-Z0-9' </dev/urandom | head -c 20)
        NEW_SECRET_KEY=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 40)
        mc admin user svcacct add myminio $USERNAME $NEW_ACCESS_KEY $NEW_SECRET_KEY
        echo "✅ 创建的新 API 信息："
        echo "Access Key: $NEW_ACCESS_KEY"
        echo "Secret Key: $NEW_SECRET_KEY"
        return
    fi

    echo "$API_LIST"
    read -p "请输入要重置的 Access Key: " OLD_KEY

    # 删除旧 Key
    mc admin user svcacct remove myminio $OLD_KEY

    # 生成新的 Key
    NEW_ACCESS_KEY=$(tr -dc 'A-Z0-9' </dev/urandom | head -c 20)
    NEW_SECRET_KEY=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 40)

    # 创建新的 Service Account
    mc admin user svcacct add myminio $USERNAME $NEW_ACCESS_KEY $NEW_SECRET_KEY

    echo "✅ 重置后的 API 信息："
    echo "Access Key: $NEW_ACCESS_KEY"
    echo "Secret Key: $NEW_SECRET_KEY"
}

# =======================
# 主菜单循环
# =======================
while true; do
    echo "=============================="
    echo "一键安装 MinIO 客户端 mc + S3 用户/ API 管理"
    echo "功能列表："
    echo "1) 安装 mc"
    echo "2) 添加 S3 用户"
    echo "3) 创建 API (随机生成 Access Key + Secret Key)"
    echo "4) 赋予访问权限"
    echo "5) 重置 API (Access Key + Secret Key)"
    echo "0) 退出"
    echo "=============================="

    read -p "请输入选项 [0-5]: " choice
    case $choice in
        1) install_mc ;;
        2) add_s3_user ;;
        3) create_api ;;
        4) attach_permission ;;
        5) reset_api ;;
        0) echo "退出脚本"; exit 0 ;;
        *) echo "无效选项，请输入 0-5" ;;
    esac
done
