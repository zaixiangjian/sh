#!/bin/bash
# =====================================================
# 一键安装 MinIO 客户端 mc + S3 用户/ API 管理脚本
# 功能：
# 1) 安装 mc
# 2) 连接 S3（不保存到本地 config）
# 3) 添加 S3 用户
# 4) 创建 API (随机生成 Access Key + Secret Key)
# 5) 赋予访问权限
# 6) 重置 API (Access Key + Secret Key)
# 7) 删除 S3 用户
# 0) 退出
# =====================================================

set -e

MC_ALIAS="myminio"
MC_CONNECTED=0

# =======================
# 安装 mc
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

# =======================
# 连接 S3（不保存配置）
# =======================
connect_s3() {
    echo "请选择连接方式:"
    echo "1) 密码连接 (Root 用户名 + 密码)"
    echo "2) 标准 S3 连接 (Access Key + Secret Key)"
    read -p "请输入选项 [1-2]: " CONNECT_TYPE

    read -p "请输入 MinIO Server Endpoint (默认 http://127.0.0.1:9000): " MINIO_ENDPOINT
    MINIO_ENDPOINT=${MINIO_ENDPOINT:-http://127.0.0.1:9000}

    if [[ "$CONNECT_TYPE" == "1" ]]; then
        read -p "请输入 Root 用户名: " MINIO_ROOT_USER
        read -s -p "请输入 Root 密码: " MINIO_ROOT_PASSWORD
        echo
        mc alias set $MC_ALIAS $MINIO_ENDPOINT $MINIO_ROOT_USER $MINIO_ROOT_PASSWORD --api S3v4 --config-dir /tmp/mc-temp
    elif [[ "$CONNECT_TYPE" == "2" ]]; then
        read -p "请输入 Access Key: " ACCESS_KEY
        read -s -p "请输入 Secret Key: " SECRET_KEY
        echo
        mc alias set $MC_ALIAS $MINIO_ENDPOINT $ACCESS_KEY $SECRET_KEY --api S3v4 --config-dir /tmp/mc-temp
    else
        echo "无效选项"
        return
    fi

    MC_CONNECTED=1
    echo "✅ 已连接到 $MINIO_ENDPOINT（不保存到本地配置）"
}

# =======================
# 列出已有 S3 用户（只显示用户名）
# =======================
list_users() {
    USERS=$(mc admin user list $MC_ALIAS 2>/dev/null | awk 'NR>1 {print $2}')
    echo "==> 当前已有 S3 用户列表："
    if [[ -z "$USERS" ]]; then
        echo "(暂无用户)"
    else
        echo "$USERS"
    fi
}

# =======================
# 添加 S3 用户
# =======================
add_s3_user() {
    list_users
    read -p "请输入新 S3 用户名: " NEW_USER
    NEW_USER_PASS=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 20)
    echo "==> 添加用户 $NEW_USER ..."
    mc admin user add $MC_ALIAS $NEW_USER $NEW_USER_PASS
    echo "✅ S3 用户 $NEW_USER 创建完成，密码: $NEW_USER_PASS"
}

# =======================
# 创建 API (Service Account)
# =======================
create_api() {
    list_users
    read -p "请输入 S3 用户名: " USERNAME
    if ! mc admin user list $MC_ALIAS | awk 'NR>1 {print $2}' | grep -qw "$USERNAME"; then
        echo "用户 $USERNAME 不存在，请先创建 S3 用户"
        return
    fi

    ACCESS_KEY=$(tr -dc 'A-Z0-9' </dev/urandom | head -c 20)
    SECRET_KEY=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 40)
    mc admin user svcacct add $MC_ALIAS $USERNAME --access-key $ACCESS_KEY --secret-key $SECRET_KEY

    echo "✅ 创建的 API 信息："
    echo "Access Key: $ACCESS_KEY"
    echo "Secret Key: $SECRET_KEY"
}

# =======================
# 赋予访问权限
# =======================
attach_permission() {
    list_users
    read -p "请输入要赋权限的 S3 用户名: " USERNAME
    echo "==> 赋予 $USERNAME 全局 readwrite 权限 ..."
    mc admin policy attach $MC_ALIAS readwrite --user $USERNAME
    echo "✅ 权限已赋予 $USERNAME"
}

# =======================
# 重置 API (删除旧 Key + 新生成)
# =======================
reset_api() {
    list_users
    read -p "请输入 S3 用户名: " USERNAME
    if ! mc admin user list $MC_ALIAS | awk 'NR>1 {print $2}' | grep -qw "$USERNAME"; then
        echo "用户 $USERNAME 不存在，请先创建 S3 用户"
        return
    fi

    # 显示当前 API Key
    API_LIST=$(mc admin user svcacct list $MC_ALIAS $USERNAME 2>/dev/null | awk 'NR>1 {print $1}')
    echo "==> 当前 $USERNAME 的 API 列表："
    if [[ -z "$API_LIST" ]]; then
        echo "(该用户还没有 API，将自动创建新的)"
    else
        echo "$API_LIST"
        for key in $API_LIST; do
            mc admin user svcacct remove $MC_ALIAS $USERNAME --access-key $key
        done
        echo "✅ 已删除旧 API Key"
    fi

    NEW_ACCESS_KEY=$(tr -dc 'A-Z0-9' </dev/urandom | head -c 20)
    NEW_SECRET_KEY=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 40)
    mc admin user svcacct add $MC_ALIAS $USERNAME --access-key $NEW_ACCESS_KEY --secret-key $NEW_SECRET_KEY

    echo "✅ 重置后的 API 信息："
    echo "Access Key: $NEW_ACCESS_KEY"
    echo "Secret Key: $NEW_SECRET_KEY"
}

# =======================
# 删除 S3 用户
# =======================
delete_user() {
    list_users
    read -p "请输入要删除的 S3 用户名: " USERNAME
    if ! mc admin user list $MC_ALIAS | awk 'NR>1 {print $2}' | grep -qw "$USERNAME"; then
        echo "用户 $USERNAME 不存在"
        return
    fi
    mc admin user remove $MC_ALIAS $USERNAME
    echo "✅ 用户 $USERNAME 已删除"
}

# =======================
# 主菜单循环
# =======================
while true; do
    echo "=============================="
    echo "一键安装 MinIO 客户端 mc + S3 用户/ API 管理"
    echo "功能列表："
    echo "1) 安装 mc"
    echo "2) 连接 S3"
    echo "3) 添加 S3 用户"
    echo "4) 创建 API (随机生成 Access Key + Secret Key)"
    echo "5) 赋予访问权限"
    echo "6) 重置 API (Access Key + Secret Key)"
    echo "7) 删除 S3 用户"
    echo "0) 退出"
    echo "=============================="

    read -p "请输入选项 [0-7]: " choice
    case $choice in
        1) install_mc ;;
        2) connect_s3 ;;
        3) add_s3_user ;;
        4) create_api ;;
        5) attach_permission ;;
        6) reset_api ;;
        7) delete_user ;;
        0) echo "退出脚本"; exit 0 ;;
        *) echo "无效选项，请输入 0-7" ;;
    esac
done
