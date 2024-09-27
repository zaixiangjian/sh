# 科技lion一键脚本工具.

## 介绍
科技Lion 的 Shell 脚本工具是一款全能脚本工具箱，专为 VPS 监控、测试和管理而设计。无论您是初学者还是经验丰富的用户，该工具都能为您提供便捷的解决方案。集成了独创的 Docker 管理功能，让您轻松管理容器化应用；LNMP建站解决方案 能帮助您快速搭建网站，站点优化，防御，备份还原迁移一应俱全；并且整合了各类系统工具面板的安装及使用，使系统维护变得更加简单。我们的目标是成为全网最优秀的 VPS 一键脚本工具，为用户提供高效、便捷的科技支持。
[视频介绍](https://www.youtube.com/watch?v=0o7oH3Dit70&t=211s)
***

### 科技lion一键脚本工具 的支持列表：
>Debian
>Ubuntu
>Cent OS
***

## 使用方法
### Debian / Ubuntu 安装下载工具
```bash
apt update -y  && apt install -y curl
```
### CentOS 安装下载工具
```bash
yum update -y  && yum install -y curl
```
***
### 一键脚本
```bash
curl -sS -O https://kejilion.pro/kejilion.sh && chmod +x kejilion.sh && ./kejilion.sh
```
or
```bash
curl -sS -O https://raw.githubusercontent.com/kejilion/sh/main/kejilion.sh && chmod +x kejilion.sh && ./kejilion.sh
```









自己配置网站文件内容
```bash
curl -sS -O https://raw.githubusercontent.com/zaixiangjian/sh/main/kejilion.sh && chmod +x kejilion.sh && ./kejilion.sh
```

自动备份到另一台vps上下载sh脚本
```bash
apt update -y && apt install -y wget sudo sshpass
```
```bash
cd /home
```
```bash
wget beifen.sh https://raw.githubusercontent.com/zaixiangjian/sh/main/beifen.sh
```
```bash
chmod +x beifen.sh
```
```bash
nano beifen.sh
```



运行sh脚本
```bash
./beifen.sh
```


定时任务
```bash
(crontab -l ; echo "0 2 * * 1 /home/beifen.sh") | crontab -
```



3.注意

如果远端VPS重装系统了或是密码更改了。需要将之前连接的认证清除掉！
ssh-keygen -f "/root/.ssh/known_hosts" -R "0.0.0.0"  

0.0.0.0替换之前VPS的IP，清除认证！


备份作者原地址视频[视频介绍](https://www.youtube.com/watch?v=0CkomEpfbhk)

***
### 觉得脚本还可以USTD TRC20打赏
![Snipaste_2024-01-17_18-01-52](https://github.com/kejilion/sh/assets/131984541/98cf2762-1bfb-4c33-af10-af0eda29fc20)

