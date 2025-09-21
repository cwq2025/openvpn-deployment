#!/bin/bash
# 安装Ansible和配置SSH互信脚本

set -e

##begin 添加颜色变量和计时
start_time=$(date +%s)
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'
##end
echo -e "\n"
echo -e "${GREEN}=== 开始安装Ansible和配置SSH互信 ===${NC}"
echo -e "\n"
# 检查参数
if [ $# -eq 0 ]; then
    echo -e "${RED}用法: $0 <服务器列表文件>${NC}"
    echo -e "${YELLOW}示例: $0 servers.txt${NC}"
    exit 1
fi

SERVER_LIST=$1

# 检查服务器列表文件是否存在
if [ ! -f "$SERVER_LIST" ]; then
    echo -e "${RED}错误: 服务器列表文件 $SERVER_LIST 不存在${NC}"
    exit 1
fi

# 安装Ansible
echo -e "${BLUE}1. 安装Ansible...${NC}"
    sudo apt update
    sudo apt install software-properties-common -y
    sudo apt-add-repository ppa:ansible/ansible lrzsz -y
    sudo apt update
    sudo apt install ansible sshpass -y

# 生成SSH密钥
echo -e "${BLUE}2. 生成SSH密钥...${NC}"
if [ ! -f ~/.ssh/id_rsa ]; then
    ssh-keygen -t rsa -b 4096 -f ~/.ssh/id_rsa -N "" -q
    echo -e "${GREEN}SSH密钥已生成${NC}"
else
    echo -e "${YELLOW}SSH密钥已存在${NC}"
fi

# 读取服务器列表
SERVERS=$(cat "$SERVER_LIST" | grep -v '^#' | grep -v '^$' | tr '\n' ' ')

##begin 修改：提前输入一次密码
echo -e "\n"
echo -e "${BLUE}3. 配置SSH互信...${NC}"
echo -e "\n"
read -s -p "请输入所有服务器的统一root密码: " UNIVERSAL_PASSWORD
echo -e "\n"
echo
echo -e "${YELLOW}开始配置SSH互信，使用统一密码...${NC}"
echo -e "\n"
##end

# 配置SSH互信
for SERVER in $SERVERS; do
    echo -e "\n"
    echo -e "${YELLOW}正在配置服务器: $SERVER${NC}"
    echo -e "\n"
    
    # 检查服务器是否可达
    if ping -c 1 -W 2 "$SERVER" &> /dev/null; then
        ##begin 修改：使用统一密码，不再每次询问
        # 复制公钥到目标服务器
        if sshpass -p "$UNIVERSAL_PASSWORD" ssh-copy-id -o StrictHostKeyChecking=no -o ConnectTimeout=10 root@"$SERVER" 2>/dev/null; then
            echo -e "${GREEN}✓ $SERVER SSH密钥复制成功${NC}"
        else
            echo -e "${YELLOW}警告: 无法自动配置 $SERVER，请手动执行: ssh-copy-id root@$SERVER${NC}"
            continue
        fi
        ##end
        
        # 测试无密码登录
        if ssh -o BatchMode=yes -o ConnectTimeout=5 root@"$SERVER" "echo '连接成功'" &> /dev/null; then
            echo -e "${GREEN}✓ $SERVER SSH互信配置成功${NC}"
        else
            echo -e "${RED}✗ $SERVER SSH互信配置失败${NC}"
        fi
    else
        echo -e "${RED}✗ 服务器 $SERVER 不可达${NC}"
    fi
done

# 创建Ansible inventory文件
echo -e "\n"
echo -e "${BLUE}4. 创建Ansible inventory文件...${NC}"
echo -e "\n"
cat > ansible_inventory.ini << EOF
[openvpn_servers]
EOF

# 添加服务器到inventory
COUNT=1
for SERVER in $SERVERS; do
    echo "server$COUNT ansible_host=$SERVER" >> ansible_inventory.ini
    COUNT=$((COUNT+1))
done

cat >> ansible_inventory.ini << EOF

[openvpn_servers:vars]
ansible_user=root
ansible_ssh_private_key_file=~/.ssh/id_rsa
ansible_ssh_common_args='-o StrictHostKeyChecking=no'
ansible_python_interpreter=/usr/bin/python3
EOF

echo -e "${GREEN}Ansible inventory文件已创建: ansible_inventory.ini${NC}"

# 测试Ansible连接
echo -e "\n"
echo -e "${BLUE}5. 测试Ansible连接...${NC}"
echo -e "\n"
ansible -i ansible_inventory.ini openvpn_servers -m ping
echo -e "\n"

##begin 计算并显示用时
end_time=$(date +%s)
total_time=$((end_time - start_time))
minutes=$((total_time / 60))
seconds=$((total_time % 60))
##end
echo -e "\n"
echo -e "${GREEN}=== Ansible和SSH互信配置完成 ===${NC}"
echo -e "\n"
echo -e "${YELLOW}总用时: ${minutes}分${seconds}秒${NC}"
echo -e "\n"

./02.sh ansible_inventory.ini
