#!/bin/bash
# 批量部署OpenVPN脚本


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
echo -e "${GREEN}=== 开始批量部署OpenVPN ===${NC}"
echo -e "\n"
echo -e "${YELLOW=}=== 端口模式随机端口 ===${NC}"
echo -e "\n"
# 检查参数
if [ $# -eq 0 ]; then
	    echo -e "${RED}用法: $0 <Ansible inventory文件>${NC}"
	        echo -e "${YELLOW}示例: $0 ansible_inventory.ini${NC}"
		    exit 1
fi

INVENTORY_FILE=$1

# 检查inventory文件是否存在
if [ ! -f "$INVENTORY_FILE" ]; then
	    echo -e "${RED}错误: Ansible inventory文件 $INVENTORY_FILE 不存在${NC}"
	        exit 1
fi

# 创建Ansible playbook
echo -e "${BLUE}1. 创建OpenVPN部署playbook...${NC}"
cat > deploy_openvpn.yml << 'EOF'
---
- name: 批量部署OpenVPN
  hosts: openvpn_servers
  become: yes
  vars:
    openvpn_script_url: "https://raw.githubusercontent.com/angristan/openvpn-install/master/openvpn-install.sh"
    client_name: "client"

  tasks:
    - name: 安装必要依赖
      package:
        name:
          - curl
          - wget
          - git
        state: present
      when: ansible_os_family == "Debian"

    - name: 安装必要依赖 (CentOS)
      package:
        name:
          - curl
          - wget
          - git
        state: present
      when: ansible_os_family == "RedHat"

    - name: 下载OpenVPN安装脚本
      get_url:
        url: "{{ openvpn_script_url }}"
        dest: "/tmp/openvpn-install.sh"
        mode: '0755'

    - name: 执行OpenVPN自动安装
      shell: |
        export AUTO_INSTALL=y
        export APPROVE_INSTALL=y
        export APPROVE_IP=y
        export IPV6_SUPPORT=n
        export PORT_CHOICE=1
        export PROTOCOL_CHOICE=3
        export DNS=1
        export COMPRESSION_ENABLED=n
        export CUSTOMIZE_ENC=n
        export CLIENT={{ client_name }}
        export PASS=1
        /tmp/openvpn-install.sh
      args:
        executable: /bin/bash
      register: install_result
      ignore_errors: yes

    - name: 检查安装结果
      debug:
        msg: "OpenVPN安装完成"
      when: install_result.rc == 0

    - name: 手动安装（如果自动安装失败）
      shell: |
        cd /root && /tmp/openvpn-install.sh
      when: install_result.rc != 0
      args:
        executable: /bin/bash

    - name: 确保客户端配置存在
      shell: |
        if [ -f /root/{{ client_name }}.ovpn ]; then
          echo "配置已存在"
        else
          echo "需要手动生成配置"
          exit 1
        fi
      register: config_check

    - name: 下载客户端配置
      fetch:
        src: "/root/{{ client_name }}.ovpn"
        dest: "ovpn_configs/{{ inventory_hostname }}_{{ client_name }}.ovpn"
        flat: yes
      when: config_check.rc == 0

- name: 合并所有客户端配置
  hosts: localhost
  connection: local
  tasks:
    - name: 创建合并脚本
      copy:
        dest: merge_ovpn.sh
        content: |
          #!/bin/bash
          CONFIG_DIR="ovpn_configs"
          OUTPUT_FILE="client-all.ovpn"
          
          echo "开始合并OpenVPN配置..."
          rm -f "$OUTPUT_FILE"
          
          count=1
          for config in "$CONFIG_DIR"/*.ovpn; do
            if [ -f "$config" ]; then
              echo "----------$count" >> "$OUTPUT_FILE"
              cat "$config" >> "$OUTPUT_FILE"
              echo -e "\n" >> "$OUTPUT_FILE"
              count=$((count+1))
            fi
          done
          
          echo "合并完成! 总共合并了 $((count-1)) 个配置"
          echo "输出文件: $OUTPUT_FILE"
          cp client-all.ovpn /root/vpn.txt
        mode: '0755'

    - name: 执行合并
      shell: ./merge_ovpn.sh

    - name: 显示合并结果
      command: cat client-all.ovpn
      register: merged_config

    - name: 显示合并的配置
      debug:
        msg: "{{ merged_config.stdout }}"
EOF

echo -e "${BLUE}2. 开始部署OpenVPN...${NC}"
ansible-playbook -i "$INVENTORY_FILE" deploy_openvpn.yml

echo -e "${BLUE}3. 创建卸载脚本...${NC}"
cat > uninstall_openvpn.yml << 'EOF'
---
- name: 卸载OpenVPN
  hosts: openvpn_servers
  become: yes
  tasks:
    - name: 执行自动卸载
      shell: |
        curl -sSL https://raw.githubusercontent.com/angristan/openvpn-install/master/openvpn-install.sh -o /tmp/uninstall.sh
        chmod +x /tmp/uninstall.sh
        printf "3\ny\n" | /tmp/uninstall.sh
        rm -f /tmp/uninstall.sh
      args:
        executable: /bin/bash
      ignore_errors: yes

    - name: 彻底清理OpenVPN相关文件
      file:
        path: "{{ item }}"
        state: absent
      loop:
        - /etc/openvpn
        - /root/*.ovpn
        - /root/client.ovpn
        - /opt/openvpn
        - /tmp/openvpn-install.sh
        - /tmp/uninstall.sh
        - /usr/local/bin/openvpn-install.sh

    - name: 停止并禁用OpenVPN服务
      systemd:
        name: openvpn-server@server.service
        state: stopped
        enabled: no
      ignore_errors: yes

    - name: 从目标服务器删除本机SSH公钥
      authorized_key:
        user: root
        key: "{{ lookup('file', '~/.ssh/id_rsa.pub') }}"
        state: absent
      ignore_errors: yes

- name: 清理本地环境和SSH密钥
  hosts: localhost
  connection: local
  tasks:
    - name: 删除本地SSH密钥对（可选）
      file:
        path: "{{ item }}"
        state: absent
      loop:
        - ~/.ssh/id_rsa
        - ~/.ssh/id_rsa.pub
      ignore_errors: yes

    - name: 从known_hosts删除服务器记录
      lineinfile:
        path: ~/.ssh/known_hosts
        regexp: "{{ item }}"
        state: absent
      loop: "{{ groups['openvpn_servers'] | map('extract', hostvars, 'ansible_host') | list }}"

    - name: 删除所有本地配置文件
      file:
        path: "{{ item }}"
        state: absent
      loop:
        - ansible_inventory.ini
        - client-all.ovpn
        - deploy_openvpn.yml
        - manage_openvpn.sh
        - merge_ovpn.sh
        - ovpn_configs
        - uninstall_openvpn.yml
        - /root/vpn.txt
        - /root/port-info.txt
        - ./ovpn_configs
        - ./port_info
        - /tmp/ovpn-configs
        - /tmp/port_info

    - name: 确认清理完成
      debug:
        msg: |
          OpenVPN已完全卸载
          SSH互信配置已清理
          注意：本地SSH密钥对已被删除
          下次部署时需要重新生成SSH密钥    
EOF

echo -e "${BLUE}4. 创建管理脚本...${NC}"
cat > manage_openvpn.sh << 'EOF'
#!/bin/bash
# OpenVPN管理脚本

case "$1" in
    status)
        ansible -i ansible_inventory.ini openvpn_servers -m shell -a "systemctl status openvpn --no-pager"
        ;;
    start)
        ansible -i ansible_inventory.ini openvpn_servers -m shell -a "systemctl start openvpn"
        ;;
    stop)
        ansible -i ansible_inventory.ini openvpn_servers -m shell -a "systemctl stop openvpn"
        ;;
    restart)
        ansible -i ansible_inventory.ini openvpn_servers -m shell -a "systemctl restart openvpn"
        ;;
    uninstall)
        echo "正在卸载OpenVPN..."
        ansible-playbook -i ansible_inventory.ini uninstall_openvpn.yml
        ;;
    *)
        echo "用法: $0 {status|start|stop|restart|uninstall}"
        exit 1
        ;;
esac
EOF

chmod +x manage_openvpn.sh

##begin 计算并显示用时
end_time=$(date +%s)
total_time=$((end_time - start_time))
minutes=$((total_time / 60))
seconds=$((total_time % 60))
##end

echo -e "${GREEN}=== OpenVPN部署完成 ===${NC}"
echo -e "${YELLOW}总用时: ${minutes}分${seconds}秒${NC}"
echo ""
echo -e "${BLUE}可用命令:${NC}"
echo -e "  ${GREEN}./manage_openvpn.sh status${NC}    # 查看状态"
echo -e "  ${GREEN}./manage_openvpn.sh start${NC}     # 启动服务"
echo -e "  ${GREEN}./manage_openvpn.sh stop${NC}      # 停止服务"
echo -e "  ${GREEN}./manage_openvpn.sh restart${NC}   # 重启服务"
echo -e "  ${GREEN}./manage_openvpn.sh uninstall${NC} # 卸载OpenVPN"
echo ""
echo -e "${BLUE}合并的客户端配置文件: ${GREEN}./vpn.txt${NC}"


