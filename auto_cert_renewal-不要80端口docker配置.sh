在源代码下添加下面配置
/home/web/docker-compose.yml


  # ⭐⭐⭐ 新增：ACME DNS 证书签发服务
  acme:
    image: neilpang/acme.sh
    container_name: acme
    restart: unless-stopped
    volumes:
      # 1. 证书输出目录（你现有的，用于 Nginx 读取）
      - ./certs:/acme.sh
      # 2. 新增：配置文件持久化（保存账户、Token、续期记录）
      - ./certs/acme_conf:/root/.acme.sh
    environment:
      - CF_Token=你的api密钥
    command: daemon



添加后重启配置

cd /home/web/
docker compose up -d
