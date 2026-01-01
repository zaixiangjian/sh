#!/bin/bash
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
# 连接 MinIO（仅 Root）
# =======================
connect_s3() {
    read -p "请输入 MinIO Server Endpoint (默认 http://127.0.0.1:9000): " MINIO_ENDPOINT
    MINIO_ENDPOINT=${MINIO_ENDPOINT:-http://127.0.0.1:9000}

    read -p "请输入 Root 用户名: " MINIO_ROOT_USER
    read -s -p "请输入 Root 密码: " MINIO_ROOT_PASSWORD
    echo

    mc alias set $MC_ALIAS $MINIO_ENDPOINT $MINIO_ROOT_USER $MINIO_ROOT_PASSWORD
    echo "✅ 已成功连接 MinIO：$MINIO_ENDPOINT"
}

# =======================
# 列出 S3 用户
# =======================
list_users() {
    echo "==> 当前已有 S3 用户列表："
    mc admin user list $MC_ALIAS | awk 'NR==1 || $1=="enabled" || $1=="disabled"'
}

# =======================
# 添加 S3 用户
# =======================
add_s3_user() {
    list_users
    read -p "请输入新 S3 用户名: " NEW_USER

    NEW_PASS=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 20)
    mc admin user add $MC_ALIAS $NEW_USER $NEW_PASS

    echo "✅ 用户创建成功"
    echo "用户名: $NEW_USER"
    echo "密码:   $NEW_PASS"
}

# =======================
# 创建 API
# =======================
create_api() {
    list_users
    read -p "请输入 S3 用户名: " USERNAME

    if ! mc admin user list $MC_ALIAS | awk '{print $2}' | grep -qw "$USERNAME"; then
        echo "❌ 用户不存在"
        return
    fi

    AK=$(tr -dc 'A-Z0-9' </dev/urandom | head -c 20)
    SK=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 40)

    mc admin user svcacct add $MC_ALIAS $USERNAME \
        --access-key $AK \
        --secret-key $SK

    echo "✅ API 创建完成"
    echo "Access Key: $AK"
    echo "Secret Key: $SK"
}

# =======================
# 赋予权限
# =======================
attach_permission() {
    list_users
    read -p "请输入要赋权的 S3 用户名: " USERNAME

    mc admin policy attach $MC_ALIAS readwrite --user $USERNAME
    echo "✅ 已赋予 readwrite 权限"
}

# =======================
# 删除 S3 用户
# =======================
delete_user() {
    list_users
    read -p "请输入要删除的 S3 用户名: " USERNAME

    if ! mc admin user list $MC_ALIAS | awk '{print $2}' | grep -qw "$USERNAME"; then
        echo "❌ 用户不存在"
        return
    fi

    mc admin user remove $MC_ALIAS $USERNAME
    echo "✅ 用户 $USERNAME 已删除"
}

# =======================
# 卸载 mc
# =======================
uninstall_mc() {
    if command -v mc &>/dev/null; then
        rm -f /usr/local/bin/mc
        echo "✅ mc 可执行文件已删除"
    else
        echo "⚠️ mc 未安装，无需删除可执行文件"
    fi

    if [ -d "$HOME/.mc" ]; then
        rm -rf "$HOME/.mc"
        echo "✅ mc 配置文件已删除：$HOME/.mc"
    else
        echo "⚠️ 未找到 mc 配置文件"
    fi
}


# =======================
# 主菜单
# =======================
while true; do
    echo "=============================="
    echo " MinIO S3 用户 / API 管理工具 "
    echo "=============================="
    echo "1) 安装 mc"
    echo "2) 连接 MinIO（Root）"
    echo "3) 添加 S3 用户"
    echo "4) 创建 API"
    echo "5) 赋予访问权限"
    echo "6) 删除 S3 用户"
    echo "7) 卸载 mc"
    echo "0) 退出"
    echo "=============================="

    read -p "请输入选项 [0-7]: " choice
    case $choice in
        1) install_mc ;;
        2) connect_s3 ;;
        3) add_s3_user ;;
        4) create_api ;;
        5) attach_permission ;;
        6) delete_user ;;
        7) uninstall_mc ;;
        0) echo "退出脚本"; exit 0 ;;
        *) echo "无效选项" ;;
    esac
done
