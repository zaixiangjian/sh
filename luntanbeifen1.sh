
#!/bin/bash

# 定时任务
# 0 4 */3 * * /home/beifen.sh
# 每3天四点备份

# SSH远程传送

# 如果你确认这是你自己的服务器，并且知道密钥变化是正常的，可以这样处理：
# SSH密码变化ssh链接输入代码


# ssh-keygen -f "/root/.ssh/known_hosts" -R "103.234.53.1"

ls -t /var/discourse/shared/standalone/backups/default/*.tar.gz | head -1 | xargs -I {} sshpass -p 'vps密码' scp -o StrictHostKeyChecking=no -P 22 {} root@vpsip:/home/论坛1



# 每三天备份一次
# crontab -e
# 0 4 */3 * * /home/beifen.sh
# 30 4 */3 * * /home/beifen2.sh
