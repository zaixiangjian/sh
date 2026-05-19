#!/bin/bash
set -e

BASE_DIR="/home/docker/google"
IMAGE_NAME="google-bot"
CONTAINER_NAME="google-bot"

install_docker() {
    if ! command -v docker >/dev/null 2>&1; then
        echo "[INFO] Docker not found, installing..."
        apt update -y
        apt install -y ca-certificates curl gnupg lsb-release
        install -m 0755 -d /etc/apt/keyrings
        curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
        echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian $(. /etc/os-release && echo "$VERSION_CODENAME") stable" > /etc/apt/sources.list.d/docker.list
        apt update -y
        apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
        systemctl enable docker
        systemctl start docker
    else
        echo "[INFO] Docker already installed."
    fi
}

create_files() {
    mkdir -p $BASE_DIR

    # Dockerfile
    cat > $BASE_DIR/Dockerfile <<'EOF'
FROM mcr.microsoft.com/playwright/python:v1.60.0-jammy

WORKDIR /app

COPY bot.py /app/bot.py
COPY bot.sh /app/bot.sh

RUN pip install --no-cache-dir playwright \
    && chmod +x /app/bot.sh

CMD ["/bin/bash", "/app/bot.sh"]
EOF

    # bot.sh
    cat > $BASE_DIR/bot.sh <<'EOF'
#!/bin/bash

LOG_DIR="/app/logs"
mkdir -p $LOG_DIR
LOG_FILE="$LOG_DIR/bot.log"

echo "[SH] Bot started: $(date)" | tee -a $LOG_FILE

while true
do
    echo "[SH] Running task..." | tee -a $LOG_FILE
    timeout 300 python3 /app/bot.py >> $LOG_FILE 2>&1 || echo "[SH] Bot crashed or timeout" | tee -a $LOG_FILE
    echo "[SH] Task done: $(date)" | tee -a $LOG_FILE

    SLEEP_TIME=$((RANDOM % 3600 + 7200))
    echo "[SH] Sleep ${SLEEP_TIME}s" | tee -a $LOG_FILE
    sleep $SLEEP_TIME

    # 删除7天以上日志
    find /app/logs -type f -mtime +7 -delete
done
EOF

    # bot.py
    cat > $BASE_DIR/bot.py <<'EOF'
import random
import time
from playwright.sync_api import sync_playwright

URLS = [
    "https://www.google.com",
    "https://www.google.com/maps",
    "https://www.google.com/search?q=weather"
]

SEARCH_KEYS = ["weather", "news", "time", "technology", "map"]

def delay(a, b):
    time.sleep(random.uniform(a, b))

print("[BOT] start session")

with sync_playwright() as p:
    browser = p.chromium.launch(
        headless=True,
        args=[
            "--no-sandbox",
            "--disable-dev-shm-usage",
            "--disable-gpu"
        ]
    )

    context = browser.new_context()
    page = context.new_page()

    for _ in range(random.randint(2, 4)):
        url = random.choice(URLS)
        print("[BOT] open:", url)
        page.goto(url)
        delay(5, 20)

        for _ in range(random.randint(2, 5)):
            page.mouse.wheel(0, random.randint(200, 900))
            delay(1, 3)

        try:
            links = page.query_selector_all("a")
            if links:
                random.choice(links).click()
                delay(3, 8)
                page.go_back()
        except:
            pass

        try:
            if "google" in page.url:
                page.fill("input[name='q']", random.choice(SEARCH_KEYS))
                page.keyboard.press("Enter")
                delay(5, 15)
        except:
            pass

        delay(3, 10)

    browser.close()

print("[BOT] end session")
EOF
}

build_image() {
    echo "[INFO] Building Docker image..."
    cd $BASE_DIR
    docker build --no-cache -t $IMAGE_NAME .
}

start_container() {
    docker rm -f $CONTAINER_NAME 2>/dev/null || true
    echo "[INFO] Starting container..."
    docker run -d \
      --name $CONTAINER_NAME \
      --restart always \
      --memory=512m \
      --cpus=0.5 \
      --log-opt max-size=10m \
      --log-opt max-file=3 \
      $IMAGE_NAME
}

run_bot_once() {
    docker exec -it $CONTAINER_NAME python3 /app/bot.py
}

view_logs() {
    docker exec -it $CONTAINER_NAME tail -f /app/logs/bot.log
}


uninstall_bot() {
    echo "[INFO] Stopping and removing container..."
    docker rm -f $CONTAINER_NAME 2>/dev/null || true
    echo "[INFO] Removing Docker image..."
    docker rmi -f $IMAGE_NAME 2>/dev/null || true
    echo "[INFO] Removing project directory..."
    rm -rf $BASE_DIR
    echo "[SUCCESS] Bot fully uninstalled."
}

# -----------------------
# 交互式菜单
# -----------------------
while true; do
    echo "=============================="
    echo "   Google Bot Installer Menu"
    echo "=============================="
    echo "1️.安装并编译镜像"
    echo "2️.启动容器"
    echo "3️.手动运行 Bot"
    echo "4️.卸载 Bot（容器/镜像/目录）"
    echo "5️.查看运行日志"
    echo "0️.退出"
    read -p "请选择操作 [0-5]: " choice

    case $choice in
        1) install_docker; create_files; build_image ;;
        2) start_container ;;
        3) run_bot_once ;;
        4) uninstall_bot ;;
        5) view_logs ;;
        0) echo "退出"; exit 0 ;;
        *) echo "无效选项" ;;
    esac
done
