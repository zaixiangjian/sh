#!/usr/bin/env bash
# 从 /root/kejilion.sh 应用市场 88 导出；构建选项已改为源码编译。

# 从指定仓库真正编译；不下载已失效的官方二进制。
minio_build_source() (
    set -euo pipefail
    for tool in git docker tee mktemp; do
        command -v "$tool" >/dev/null || { echo "❌ 缺少依赖：$tool，请先安装环境"; exit 1; }
    done
    docker info >/dev/null
    mkdir -p "$build_dir"
    local work log go_version
    work=$(mktemp -d "$build_dir/minio-source.XXXXXX")
    log="$work/build.log"
    echo "源码及日志目录：$work"
    git clone --depth 1 "$my_github_url" "$work/source"
    cd "$work/source"
    go_version=$(sed -n 's/^toolchain go//p' go.mod)
    if [ -z "$go_version" ]; then
        go_version=$(sed -n 's/^go //p' go.mod)
    fi
    [[ "$go_version" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]] || { echo "❌ 无法识别 Go 版本"; exit 1; }
    echo "--- 源码提交：$(git rev-parse HEAD)，Go：$go_version ---"
    # 仓库 .dockerignore 排除了 .git；版本生成器需要它。
    printf '.git/objects/pack/*.keep\n' > Dockerfile.source.dockerignore
    cat > Dockerfile.source <<'DOCKERFILE'
ARG GO_VERSION=1.24.8
FROM golang:${GO_VERSION}-bookworm AS builder
WORKDIR /src
ENV CGO_ENABLED=0 GOTOOLCHAIN=local GOMAXPROCS=2
COPY go.mod go.sum ./
RUN --mount=type=cache,target=/go/pkg/mod go mod download
COPY . .
RUN --mount=type=cache,target=/go/pkg/mod --mount=type=cache,target=/root/.cache/go-build \
    ldflags=$(go run buildscripts/gen-ldflags.go) && \
    go build -p 2 -trimpath -tags kqueue -ldflags="$ldflags" -o /out/minio .

FROM debian:bookworm-slim
COPY --from=builder /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/ca-certificates.crt
COPY --from=builder /out/minio /usr/bin/minio
COPY dockerscripts/docker-entrypoint.sh /usr/bin/docker-entrypoint.sh
RUN chmod 755 /usr/bin/minio /usr/bin/docker-entrypoint.sh
EXPOSE 9000 9001
VOLUME ["/data"]
ENTRYPOINT ["/usr/bin/docker-entrypoint.sh"]
CMD ["minio"]
DOCKERFILE
    echo "--- 开始源码编译（并行数 2，首次下载依赖可能较慢）---"
    if ! DOCKER_BUILDKIT=1 docker build --progress=plain --build-arg "GO_VERSION=$go_version" \
        -f Dockerfile.source -t "$my_docker_img" . 2>&1 | tee "$log"; then
        echo "❌ 构建失败，日志：$log"
        exit 1
    fi
    docker run --rm --network none "$my_docker_img" --version
    echo "✅ 源码编译及镜像版本验证成功：$my_docker_img"
    echo "日志：$log"
    echo "未推送镜像，也未替换现有 MinIO 容器。"
)

while true; do
    clear
    echo "------------------------------------------------"
    echo "      MinIO 自编译管理脚本 (源码构建)"
    echo "------------------------------------------------"
    echo "【源码与镜像管理】"
    echo "1) 安装环境并修复 Docker"
    echo "2) 一键克隆源码并编译 Docker 镜像"
    echo "3) 登录 Docker Hub"
    echo "4) 推送镜像到 Docker Hub"
    echo "------------------------------------------------"
    echo "【容器部署管理】"
    echo "11) 部署/启动 MinIO (/home/docker/minio)"
    echo "12) 更新镜像到最新版本"
    echo "13) 卸载 MinIO"
    echo "0) 返回主菜单"
    echo "------------------------------------------------"
    read -p "请输入操作编号: " ct_choice

    build_dir="/home/docker/build"
    install_dir="/home/docker/minio"
    my_github_url="https://github.com/zaixiangjian/minio.git"
    my_docker_img="zaixiangjian/minio:latest"
    TARGETARCH=amd64
    RELEASE=latest

    case $ct_choice in
        1)
            echo -e "\n--- [1/3] 修复系统基础环境 ---"
            sudo rm -f /var/lib/dpkg/lock-frontend /var/lib/apt/lists/lock &>/dev/null
            sudo dpkg --configure -a
            sudo apt --fix-broken install -y

            echo -e "\n--- [2/3] 安装基础工具 ---"
            sudo apt update
            sudo apt install -y git curl ca-certificates build-essential make golang

            echo -e "\n--- [3/3] 检查并启动 Docker ---"
            if ! command -v docker &> /dev/null; then
                curl -fsSL https://get.docker.com | bash -
            fi
            sudo systemctl enable --now docker
            sudo chmod 666 /var/run/docker.sock
            echo -e "\n✅ 环境准备就绪！"
            read -n1 -r -p "回车继续..." key
            ;;

        2)
            minio_build_source
            if [ $? -ne 0 ]; then
                echo "❌ 源码构建未完成，请查看上方错误及日志"
            fi
            read -n1 -r -p "回车继续..." key
            ;;

        3)
            sudo docker login
            read -n1 -r -p "回车继续..." key
            ;;

        4)
            echo "正在推送镜像到 Docker Hub..."
            sudo docker push "$my_docker_img"
            read -n1 -r -p "回车继续..." key
            ;;

11)
            echo "--- 部署/启动 MinIO ---"
            
            # 1. 交互式获取账号
            read -p "请输入 MinIO 管理员账号 (直接回车将随机生成): " input_user
            if [ -z "$input_user" ]; then
                MINIO_ROOT_USER=$(tr -dc 'A-Z0-9' </dev/urandom | head -c 20)
                echo "-> 使用随机账号: $MINIO_ROOT_USER"
            else
                MINIO_ROOT_USER=$input_user
            fi

            # 2. 交互式获取密码
            read -p "请输入 MinIO 管理员密码 (直接回车将随机生成): " input_pass
            if [ -z "$input_pass" ]; then
                MINIO_ROOT_PASSWORD=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 40)
                echo "-> 使用随机密码: $MINIO_ROOT_PASSWORD"
            else
                MINIO_ROOT_PASSWORD=$input_pass
            fi

            # 3. 执行部署
            sudo docker rm -f minio &>/dev/null
            mkdir -p "$install_dir/data"
            sudo chmod -R 777 "$install_dir/data"

            sudo docker run -d \
                --name minio \
                --restart unless-stopped \
                -p 9000:9000 \
                -p 9001:9001 \
                -v "$install_dir/data:/data" \
                -e MINIO_ROOT_USER="$MINIO_ROOT_USER" \
                -e MINIO_ROOT_PASSWORD="$MINIO_ROOT_PASSWORD" \
                "$my_docker_img" server /data --console-address ":9001"

            if [ $? -eq 0 ]; then
                loc_v4=$(hostname -I | awk '{print $1}')
                echo "------------------------------------------------"
                echo "✅ 启动成功！"
                echo "管理界面: http://$loc_v4:9001"
                echo "API 地址: http://$loc_v4:9000"
                echo "管理员账号: $MINIO_ROOT_USER"
                echo "管理员密码: $MINIO_ROOT_PASSWORD"
                echo "------------------------------------------------"
                echo "请务必妥善保存上述信息！"
            else
                echo "❌ 启动失败，请检查 Docker 日志"
            fi
            read -n1 -r -p "回车继续..." key
            ;;

        12)
            echo "--- 拉取最新镜像 ---"
            sudo docker pull "$my_docker_img"
            echo "✅ 镜像已更新"
            read -n1 -r -p "回车继续..." key
            ;;

        13)
            echo "--- 卸载 MinIO（删除容器与镜像，保留本地数据）---"

            # 删除容器（如果存在）
            if sudo docker ps -a --format '{{.Names}}' | grep -q '^minio$'; then
                sudo docker rm -f minio
                echo "✅ 容器已删除"
            else
                echo "ℹ️ 容器不存在"
            fi

            # 删除镜像（如果存在）
            if sudo docker images --format '{{.Repository}}:{{.Tag}}' | grep -q "^$my_docker_img$"; then
                sudo docker rmi "$my_docker_img"
                echo "✅ 镜像已删除"
            else
                echo "ℹ️ 镜像不存在"
            fi

            echo "📦 本地数据目录已保留：$install_dir"
            read -n1 -r -p "回车继续..." key
            ;;

        0) break ;;
        *) echo "无效选择"; sleep 1 ;;
    esac
done
