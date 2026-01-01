#!/bin/bash
# =====================================================
# 一键安装 MinIO 客户端 mc + S3 用户/ API 管理脚本
# 功能：
# 1) 安装 mc
# 2) 连接 S3（支持 Root 密码或标准 S3 Key）
# 3) 添加 S3 用户
# 4) 创建 API (随机生成 Access Key + Secret Key)
# 5) 赋予访问权限
# 6) 重置 API (Access Key + Secret Key)
# 7) 删除 S3 用户
# 0) 退出
# =====================================================

set -e

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
# 连接 S3
# =======================
connect_s3() {
    echo "请选择连接方式:"
    echo "1) 密码连接 (Root 用户名 + 密码)"
    echo "2) 标准 S3 连接 (Access Key + Secret Key)"
    read -p "请输入选项 [1-2]: " CONNECT_TYPE

    if [[ "$CONNECT_TYPE" == "1" ]]; then
        read -p "请输入 MinIO Server Endpoint (默认 http://127.0.0.1:9000): " MINIO_ENDPOINT
        MINIO_ENDPOINT=${MINIO_ENDPOINT:-http://127.0.0.1:9000}
        read -p "请输入 Root 用户名: " MINIO_ROOT_USER
        read -s -p "请输入 Root 密码: " MINIO_ROOT_PASSWORD
        echo
        mc alias set myminio $MINIO_ENDPOINT $MINIO_ROOT_USER $MINIO_ROOT_PASSWORD
        echo "✅ 已连接 MinIO (密码连接)"
    elif [[ "$CONNECT_TYPE" == "2" ]]; then
        read -p "请输入 Endpoint (例: http://127.0.0.1:9000): " S3_ENDPOINT
        read -p "请输入 Access Key ID: " ACCESS_KEY
        read -p "请输入 Secret Key: " SECRET_KEY
        mc alias set myminio $S3_ENDPOINT $ACCESS_KEY $SECRET_KEY
        echo "✅ 已连接 MinIO (标准 S3 连接)"
    else
        echo "无效选项"
    fi
}

# =======================
# 添加 S3 用户
# =======================
add_s3_user() {
    read -p "请输入新 S3 用户名: " NEW_USER

    # 自动生成 20 位随机密码
    NEW_USER_PASS=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 20)

    # 添加用户
    echo "==> 添加用户 $NEW_USER ..."
    mc admin user add myminio $NEW_USER $NEW_USER_PASS

    echo "✅ S3 用户 $NEW_USER 创建完成，密码: $NEW_USER_PASS"
}

# =======================
# 创建 API (Service Account)
# =======================
create_api() {
    read -p "请输入 S3 用户名: " USERNAME

    # 检查用户是否存在
    if ! mc admin user list myminio | awk 'NR>1 {print $2}' | grep -qw "$USERNAME"; then
        echo "用户 $USERNAME 不存在，请先创建 S3 用户"
        return
    fi

    # 随机生成 Access Key 和 Secret Key
    ACCESS_KEY=$(tr -dc 'A-Z0-9' </dev/urandom | head -c 20)
    SECRET_KEY=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 40)

    # 创建 Service Account (API) ✅ 修复加 --access-key --secret-key
    mc admin user svcacct add myminio $USERNAME --access-key $ACCESS_KEY --secret-key $SECRET_KEY 2>/dev/null || \
        echo "注意：API 可能已存在，尝试使用其它名称或重置"

    echo "✅ 创建的 API 信息："
    echo "Access Key: $ACCESS_KEY"
    echo "Secret Key: $SECRET_KEY"
}

# =======================
# 赋予访问权限
# =======================
attach_permission() {
    echo "==> 当前已有 S3 用户列表："
    mc admin user list myminio | awk 'NR>1 {print $2}' || echo "(暂无用户)"
    
    read -p "请输入要赋权限的 S3 用户名: " USERNAME
    echo "==> 赋予 $USERNAME 全局 readwrite 权限 ..."
    mc admin policy attach myminio readwrite --user $USERNAME
    echo "✅ 权限已赋予 $USERNAME"
}

# =======================
# 重置 API (删除旧 Key + 新生成)
# =======================
reset_api() {
    read -p "请输入 S3 用户名: " USERNAME

    # 列出用户现有子密钥
    echo "==> 当前 $USERNAME 的 API 列表："
    API_LIST=$(mc admin user svcacct list myminio $USERNAME | grep "Access Key" | awk '{print $1}')

    if [[ -z "$API_LIST" ]]; then
        echo "(该用户还没有 API，先创建一个)"
        NEW_ACCESS_KEY=$(tr -dc 'A-Z0-9' </dev/urandom | head -c 20)
        NEW_SECRET_KEY=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 40)
        mc admin user svcacct add myminio $USERNAME --access-key $NEW_ACCESS_KEY --secret-key $NEW_SECRET_KEY
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
    mc admin user svcacct add myminio $USERNAME --access-key $NEW_ACCESS_KEY --secret-key $NEW_SECRET_KEY

    echo "✅ 重置后的 API 信息："
    echo "Access Key: $NEW_ACCESS_KEY"
    echo "Secret Key: $NEW_SECRET_KEY"
}

# =======================
# 删除 S3 用户
# =======================
delete_s3_user() {
    echo "==> 当前已有 S3 用户列表："
    mc admin user list myminio | awk 'NR>1 {print $2}' || echo "(暂无用户)"

    read -p "请输入要删除的 S3 用户名: " USERNAME

    if ! mc admin user list myminio | awk 'NR>1 {print $2}' | grep -qw "$USERNAME"; then
        echo "用户 $USERNAME 不存在"
        return
    fi

    mc admin user remove myminio $USERNAME
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
        7) delete_s3_user ;;
        0) echo "退出脚本"; exit 0 ;;
        *) echo "无效选项，请输入 0-7" ;;
    esac
done
