#!/bin/bash

BACKUP_DIR="/root/.openclaw/backups"

# =========================
# 备份与还原菜单
# =========================
backup_menu() {

    mkdir -p "$BACKUP_DIR"

    while true; do

        clear

        echo "======================================="
        echo "OpenClaw 备份与还原"
        echo "======================================="
        echo "备份目录: $BACKUP_DIR"

        BACKUP_FILES=$(ls -A "$BACKUP_DIR" 2>/dev/null)

        if [ -z "$BACKUP_FILES" ]; then
            echo "暂无备份文件"
        else
            echo
            ls -lh "$BACKUP_DIR"
        fi

        echo "---------------------------------------"
        echo "1. 备份记忆全量"
        echo "2. 还原记忆全量"
        echo "3. 备份 OpenClaw 项目（默认安全模式）"
        echo "4. 还原 OpenClaw 项目（高级/高风险）"
        echo "5. 删除备份文件"
        echo "0. 返回上一级"
        echo "---------------------------------------"

        read -p "请输入你的选择: " backup_choice

        case $backup_choice in

            1)
                echo
                echo "开始备份记忆..."

                tar -czf \
                "$BACKUP_DIR/memory-$(date +%Y%m%d-%H%M%S).tar.gz" \
                ~/.openclaw/memory 2>/dev/null

                echo "记忆备份完成"
                ;;

            2)
                echo
                echo "当前备份文件:"
                ls "$BACKUP_DIR"

                echo
                read -p "输入要还原的文件名: " restore_file

                tar -xzf \
                "$BACKUP_DIR/$restore_file" \
                -C /

                echo "记忆还原完成"
                ;;

            3)
                echo
                echo "开始备份 OpenClaw 项目..."

                tar -czf \
                "$BACKUP_DIR/openclaw-$(date +%Y%m%d-%H%M%S).tar.gz" \
                ~/.openclaw 2>/dev/null

                echo "项目备份完成"
                ;;

            4)
                echo
                echo "警告：此操作可能覆盖当前数据"

                read -p "确认继续？(y/n): " confirm

                if [ "$confirm" = "y" ]; then

                    echo
                    echo "当前备份文件:"
                    ls "$BACKUP_DIR"

                    echo
                    read -p "输入要还原的文件名: " restore_project

                    tar -xzf \
                    "$BACKUP_DIR/$restore_project" \
                    -C /

                    echo "项目还原完成"
                fi
                ;;

            5)
                echo
                echo "当前备份文件:"
                ls "$BACKUP_DIR"

                echo
                read -p "输入要删除的文件名: " del_file

                rm -f "$BACKUP_DIR/$del_file"

                echo "删除完成"
                ;;

            0)
                break
                ;;

            *)
                echo "无效输入"
                ;;

        esac

        echo
        read -p "按回车继续..."
    done
}

# =========================
# 主菜单
# =========================
while true; do

    clear

    echo "OPENCLAW 管理工具"
    echo
    echo "未安装 未运行"
    echo "======================================="
    echo "1.  安装"
    echo "2.  启动"
    echo "3.  停止"
    echo "--------------------"
    echo "4.  状态日志查看"
    echo "5.  换模型"
    echo "6.  API管理"
    echo "7.  机器人连接对接"
    echo "8.  插件管理（安装/删除）"
    echo "9.  技能管理（安装/删除）"
    echo "10. 编辑主配置文件"
    echo "11. 配置向导"
    echo "12. 健康检测与修复"
    echo "13. WebUI访问与设置"
    echo "14. TUI命令行对话窗口"
    echo "15. 记忆/Memory"
    echo "16. 权限管理"
    echo "17. 多智能体管理"
    echo "--------------------"
    echo "18. 备份与还原"
    echo "19. 更新"
    echo "20. 卸载"
    echo "--------------------"
    echo "0. 返回上一级"
    echo

    read -p "请输入选项: " choice

    case $choice in

        1)
            echo
            echo "开始安装 OpenClaw..."

            curl -fsSL https://openclaw.ai/install.sh | bash
            ;;

        2)
            echo
            echo "启动 OpenClaw..."

            systemctl start openclaw 2>/dev/null

            docker start openclaw 2>/dev/null
            ;;

        3)
            echo
            echo "停止 OpenClaw..."

            systemctl stop openclaw 2>/dev/null

            docker stop openclaw 2>/dev/null
            ;;

        4)
            journalctl -u openclaw -f
            ;;

        5)
            echo
            echo "换模型功能开发中..."
            ;;

        6)
            echo
            echo "API管理功能开发中..."
            ;;

        7)
            echo
            echo "机器人连接功能开发中..."
            ;;

        8)
            echo
            echo "插件管理功能开发中..."
            ;;

        9)
            echo
            echo "技能管理功能开发中..."
            ;;

        10)
            nano ~/.openclaw/config.json
            ;;

        11)
            echo
            echo "配置向导开发中..."
            ;;

        12)
            echo
            echo "健康检测中..."

            df -h
            ;;

        13)
            echo
            echo "WebUI 地址:"
            echo "http://$(curl -s ifconfig.me):3000"
            ;;

        14)
            echo
            echo "进入 TUI 模式..."

            openclaw
            ;;

        15)
            echo
            echo "记忆管理开发中..."
            ;;

        16)
            echo
            echo "权限管理开发中..."
            ;;

        17)
            echo
            echo "多智能体管理开发中..."
            ;;

        18)
            backup_menu
            ;;

        19)
            echo
            echo "更新 OpenClaw..."

            curl -fsSL https://openclaw.ai/install.sh | bash
            ;;

        20)
            echo
            echo "卸载 OpenClaw..."

            docker rm -f openclaw 2>/dev/null

            rm -rf ~/.openclaw

            echo "卸载完成"
            ;;

        0)
            clear
            exit
            ;;

        *)
            echo
            echo "无效输入"
            ;;

    esac

    echo
    read -p "按回车继续..."
done
