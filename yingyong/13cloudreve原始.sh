      13)
      send_stats "搭建网盘"
      has_ipv4_has_ipv6

      docker_name=cloudreve
      docker_port=5212
      while true; do
        check_docker_app
        clear
        echo -e "网盘服务 $check_docker"
        echo "cloudreve是一个支持多家云存储的网盘系统"
        echo "视频介绍: https://www.bilibili.com/video/BV13F4m1c7h7?t=0.1"
        if docker inspect "$docker_name" &>/dev/null; then
          check_docker_app_ip
        fi
        echo ""

        echo "------------------------"
        echo "1. 安装           2. 更新           3. 卸载"
        echo "------------------------"
        echo "0. 返回上一级"
        echo "------------------------"
        read -e -p "输入你的选择: " choice

        case $choice in
          1)
            install_docker
            cd /home/ && mkdir -p docker/cloud && cd docker/cloud && mkdir temp_data && mkdir -vp cloudreve/{uploads,avatar} && touch cloudreve/conf.ini && touch cloudreve/cloudreve.db && mkdir -p aria2/config && mkdir -p data/aria2 && chmod -R 777 data/aria2
            curl -o /home/docker/cloud/docker-compose.yml ${gh_proxy}https://raw.githubusercontent.com/zaixiangjian/docker/main/cloudreve-docker-compose.yml
            cd /home/docker/cloud/ && docker compose up -d

            clear
            echo "cloudreve已经安装完成"
            check_docker_app_ip
            sleep 3
            docker logs cloudreve
            echo ""


            ;;

          2)
            docker rm -f cloudreve
            docker rmi -f cloudreve/cloudreve:latest
            docker rm -f aria2
            docker rmi -f p3terx/aria2-pro
            cd /home/ && mkdir -p docker/cloud && cd docker/cloud && mkdir temp_data && mkdir -vp cloudreve/{uploads,avatar} && touch cloudreve/conf.ini && touch cloudreve/cloudreve.db && mkdir -p aria2/config && mkdir -p data/aria2 && chmod -R 777 data/aria2
            curl -o /home/docker/cloud/docker-compose.yml ${gh_proxy}https://raw.githubusercontent.com/zaixiangjian/docker/main/cloudreve-docker-compose.yml
            cd /home/docker/cloud/ && docker compose up -d
            clear
            echo "cloudreve已经安装完成"
            check_docker_app_ip
            sleep 3
            docker logs cloudreve
            echo ""
            ;;
          3)

            docker rm -f cloudreve
            docker rmi -f cloudreve/cloudreve:latest
            docker rm -f aria2
            docker rmi -f p3terx/aria2-pro
            rm -rf /home/docker/cloud
            echo "应用已卸载"

            ;;

          0)
            break
            ;;
          *)
            break
            ;;

        esac
        break_end
      done
        ;;
