#!/bin/bash

# =========================================
# 显示当前 Rclone 定时任务
# =========================================
show_cron_jobs() {
    echo "======================================"
    echo "Rclone 定时任务："
    crontab -l 2>/dev/null | grep "s3beifen" >/dev/null
    if [[ $? -ne 0 ]]; then
        echo "无"
    else
        crontab -l | grep "s3beifen"
    fi
    echo "======================================"
}

# =========================================
# 创建备份任务（5/6/7通用）
# =========================================
create_backup_job() {
    script_name="$1"

    echo "======== 添加 Rclone 备份任务 ($script_name) ========"

    read -p "请输入要备份的目录名（默认：home）: " in_dir

    # 默认 home
    if [[ -z "$in_dir" ]]; then
        in_dir="home"
    fi

    # 自动生成目录格式：/home/
    local_dir="/${in_dir%/}/"

    echo "识别目录：$local_dir"

    # 防止 "/"
    if [[ "$local_dir" == "/" ]]; then
        echo "❌ 不允许备份系统根目录 /"
        return
    fi

    dir_name="${in_dir}"

    echo "目录名称成功识别：$dir_name"

    echo
    echo "当前 Rclone 远程："
    rclone listremotes
    echo

    read -p "请输入 Rclone 名称（例如 r2）: " remote_name
    read -p "请输入存储桶名称（例如 bf19）: " bucket_name

    # 生成 rclone copy 命令
    backup_cmd="rclone copy ${local_dir} ${remote_name}:${bucket_name}/服务器备份/${dir_name}"

    echo
    echo "生成的命令："
    echo "$backup_cmd"
    echo

    # 写入脚本
    echo "#!/bin/bash" > /root/${script_name}
    echo "$backup_cmd" >> /root/${script_name}
    chmod +x /root/${script_name}

    echo "备份脚本已创建：/root/${script_name}"

    echo "先执行一次备份……"
    bash /root/${script_name}

    echo
    echo "======== 设置定时任务 ========"

    read -p "每几天运行一次（0 = 每小时模式）: " period

    if [[ "$period" == "0" ]]; then
        read -p "每几小时运行一次（例如 4）: " hours
        read -p "几分执行（0-59）: " minute
        cron_rule="$minute */$hours * * * /bin/bash /root/${script_name}"
    else
        read -p "几点执行（0-23）: " hour
        read -p "几分执行（0-59）: " minute
        cron_rule="$minute $hour */$period * * /bin/bash /root/${script_name}"
    fi

    # 写入 crontab（先去掉已有相同脚本的任务）
    (crontab -l 2>/dev/null | grep -v "/root/${script_name}"; echo "$cron_rule") | crontab -

    echo
    echo "定时任务已添加："
    echo "$cron_rule"
    echo
}

# =========================================
# 删除定时任务并列出已有任务
# =========================================
delete_backup_jobs() {
    echo "======= 当前 Rclone 定时任务 ======="
    crontab -l | grep "s3beifen"
    echo "===================================="
    read -p "是否删除所有 s3beifen 相关任务？(y/n): " confirm

    if [[ "$confirm" == "y" ]]; then
        crontab -l | grep -v "s3beifen" | crontab -
        echo "定时任务已删除。"
    else
        echo "取消删除。"
    fi
}

# =========================================
# 主菜单循环
# =========================================
while true; do
clear
show_cron_jobs

echo "官网: https://rclone.org/"
echo
echo "1. 安装 Rclone"
echo "2. 获取配置文件路径"
echo "3. 修改配置文件"
echo "4. 查看已添加的 Rclone 远程"
echo "5. 添加目录备份任务 (生成 s3beifen.sh)"
echo "6. 添加目录备份任务 (生成 s3beifen1.sh)"
echo "7. 添加目录备份任务 (生成 s3beifen2.sh)"
echo "8. 删除定时任务"
echo "9. 卸载 Rclone"
echo "0. 退出脚本"
echo

read -p "请输入操作编号: " choice

case $choice in

1)
    sudo -v
    curl https://rclone.org/install.sh | sudo bash
    ;;

2)
    rclone config file
    ;;

3)
    nano /root/.config/rclone/rclone.conf
    ;;

4)
    rclone listremotes
    ;;

5)
    create_backup_job "s3beifen.sh"
    ;;

6)
    create_backup_job "s3beifen1.sh"
    ;;

7)
    create_backup_job "s3beifen2.sh"
    ;;

8)
    delete_backup_jobs
    ;;

9)
    sudo rm -f /usr/bin/rclone
    sudo rm -rf /root/.config/rclone
    echo "Rclone 已卸载"
    ;;

0)
    exit
    ;;

*)
    echo "无效输入"
    ;;
esac

read -p "按回车键继续……"

done
