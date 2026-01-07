#!/bin/bash

# =================================================================
# LibreNMS Agent 安全強化版自動化腳本
# 適用環境：Ubuntu / Webinoly / PHP 8.x
# =================================================================

# 確保以 root 權限執行
if [[ $EUID -ne 0 ]]; then
   echo "請使用 sudo 執行此腳本"
   exit 1
fi

# --- 1. 互動式參數輸入 ---
echo "--- 步驟 1: 設定基礎資訊 ---"
read -p "請輸入 SNMPv3 使用者名稱: " SNMP_USER
read -p "請輸入 SNMPv3 認證密碼 (SHA): " SNMP_PASS
read -p "請輸入 SNMPv3 加密密碼 (AES): " SNMP_PRIV
read -p "請輸入此主機名稱 (sysName): " SYS_NAME
read -p "請輸入主機位置 (sysLocation): " SYS_LOC

# --- 2. PHP 版本偵測 ---
# 自動尋找 /etc/php 下的資料夾名稱 (如 8.3)
PHP_VER=$(ls /etc/php | head -n 1)
if [ -z "$PHP_VER" ]; then
    echo "錯誤：找不到 /etc/php 資料夾，請確認環境。"
    exit 1
fi
echo "偵測到 PHP 版本: $PHP_VER"

# --- 3. 安裝必要套件 ---
echo "安裝核心元件與 PHP $PHP_VER 套件..."
apt update
apt install -y rrdtool snmp snmpd
apt install -y php${PHP_VER}-cli php${PHP_VER}-mysql
apt install -y libfile-slurp-perl libjson-perl libmime-base64-perl libstring-shellquote-perl

# --- 4. 最小化 Sudo 權限設定 ---
echo "正在設定精確的 Sudo 權限..."
cat > /etc/sudoers.d/debian-snmp <<EOF
Debian-snmp ALL=(ALL) NOPASSWD: /bin/cat /sys/devices/virtual/dmi/id/product_serial
EOF
chmod 440 /etc/sudoers.d/debian-snmp

# --- 5. 配置 snmpd.conf ---
wget https://raw.githubusercontent.com/librenms/librenms/refs/heads/master/snmpd.conf.example -O /etc/snmp/snmpd.conf
cat >> /etc/snmp/snmpd.conf <<EOF
sysName $SYS_NAME
sysLocation $SYS_LOC
sysContact Eric Chuang <eric.chuang@applemint.tech>
agentAddress udp:161,udp6:161

# 偵測硬體資訊
extend manufacturer '/bin/cat /sys/devices/virtual/dmi/id/sys_vendor'
extend hardware '/bin/cat /sys/devices/virtual/dmi/id/product_name'
extend serial '/usr/bin/sudo /bin/cat /sys/devices/virtual/dmi/id/product_serial'

# 使用 SNMP v3 協定
createUser $SNMP_USER SHA "$SNMP_PASS" AES "$SNMP_PRIV"
rouser $SNMP_USER priv

# OS 偵測
extend distro /usr/bin/distro
EOF

# --- 6. MySQL 專用監控帳號建立 (改進版) ---
echo ""
echo "--- 步驟 2: MySQL 監控帳號設定 ---"



# 檢查是否已有現成密碼，若有則沿用，避免中斷導致密碼不一致
if [ -f "/etc/snmp/mysql.cnf" ]; then
    echo "偵測到現有設定檔，正在讀取舊密碼..."
    MONITOR_PASS=$(sudo grep "\$mysql_pass =" /etc/snmp/mysql.cnf | cut -d"'" -f2)
else
    echo "建立新密碼..."
    MONITOR_PASS=$(openssl rand -base64 16)
fi

read -p "請輸入資料庫 root 密碼 (webinoly -dbpass): " DB_ROOT_PASS

# 使用相同的密碼指令同時確保帳號存在與密碼正確
mysql -u root -p"$DB_ROOT_PASS" <<MYSQL_SCRIPT
CREATE USER IF NOT EXISTS 'librenms-monitor'@'localhost' IDENTIFIED BY '$MONITOR_PASS';
ALTER USER 'librenms-monitor'@'localhost' IDENTIFIED BY '$MONITOR_PASS';
GRANT PROCESS, REPLICATION CLIENT, SELECT ON *.* TO 'librenms-monitor'@'localhost';
FLUSH PRIVILEGES;
MYSQL_SCRIPT

# 確保快取目錄與權限
mkdir -p /var/cache/librenms/
chown -R Debian-snmp:Debian-snmp /var/cache/librenms/

# 重新寫入或建立設定檔
cat > /etc/snmp/mysql.cnf <<EOF
<?php
\$mysql_user = 'librenms-monitor';
\$mysql_pass = '$MONITOR_PASS';
\$mysql_host = 'localhost';
\$mysql_port = 3306;
\$chk_options['slave'] = false;
EOF

# 權限校正
chown root:Debian-snmp /etc/snmp/mysql.cnf
chmod 640 /etc/snmp/mysql.cnf

# --- 7. 下載服務擴充腳本 ---
echo "下載並設定服務擴充腳本..."

declare -A scripts=(
    ["/usr/bin/distro"]="https://raw.githubusercontent.com/librenms/librenms-agent/master/snmp/distro"
    ["/etc/snmp/osupdate"]="https://raw.githubusercontent.com/librenms/librenms-agent/master/snmp/osupdate"
    ["/etc/snmp/linux_softnet_stat"]="https://raw.githubusercontent.com/librenms/librenms-agent/master/snmp/linux_softnet_stat"
    ["/etc/snmp/nginx"]="https://raw.githubusercontent.com/librenms/librenms-agent/master/snmp/nginx"
    ["/etc/snmp/php-fpm"]="https://github.com/librenms/librenms-agent/raw/master/snmp/php-fpm"
    ["/etc/snmp/redis.py"]="https://raw.githubusercontent.com/librenms/librenms-agent/master/snmp/redis.py"
    ["/etc/snmp/mysql"]="https://raw.githubusercontent.com/librenms/librenms-agent/master/snmp/mysql"
)

for path in "${!scripts[@]}"; do
    wget "${scripts[$path]}" -O "$path"
    chmod +x "$path"
    chown root:Debian-snmp "$path"
done

# PHP-FPM 延伸設定
cat > /usr/local/etc/php-fpm_extend.json <<EOF
{
  "pools":{
    "www": "http://localhost/status"
  }
}
EOF
chown root:Debian-snmp /usr/local/etc/php-fpm_extend.json
chmod 640 /usr/local/etc/php-fpm_extend.json

# 加入 snmpd.conf
cat >> /etc/snmp/snmpd.conf <<EOF
extend osupdate /etc/snmp/osupdate
extend linux_softnet_stat /etc/snmp/linux_softnet_stat -b
extend nginx /etc/snmp/nginx
extend phpfpmsp /etc/snmp/php-fpm
extend redis /etc/snmp/redis.py
EOF

# --- 8. Webinoly Nginx 額外調整 ---
cat > /etc/nginx/conf.d/librenms.conf <<EOF
server {
    listen 127.0.0.1:80;
    listen [::1]:80;
    server_name localhost;
    location /nginx-status {
        stub_status on;
        access_log off;
        allow 127.0.0.1;
        allow ::1;
        deny all;
    }
    location ~ ^/(status|ping)\$ {
        access_log off;
        allow 127.0.0.1;
        allow ::1;
        deny all;
        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME \$fastcgi_script_name;
        fastcgi_pass unix:/run/php/php${PHP_VER}-fpm.sock;
    }
}
EOF

# --- 9. 最終權限校驗 ---
echo ""
echo "--- 步驟 3: 權限校驗 (以 Debian-snmp 身份測試) ---"
CHECK_FILES=("/usr/bin/distro" "/etc/snmp/nginx" "/etc/snmp/mysql" "/etc/snmp/php-fpm")
for f in "${CHECK_FILES[@]}"; do
    if sudo -u Debian-snmp [ -x "$f" ]; then
        echo "[OK] 可執行: $f"
    else
        echo "[FAIL] 執行失敗: $f"
        exit 1
    fi
done

if sudo -u Debian-snmp [ -r "/etc/snmp/mysql.cnf" ]; then
    echo "[OK] 設定檔讀取測試通過"
else
    echo "[FAIL] mysql.cnf 無法讀取"
    exit 1
fi

# --- 10. 重啟服務與安裝 Agent ---
echo "重啟系統服務..."
systemctl restart nginx
systemctl enable snmpd && systemctl restart snmpd

# 下載 LibreNMS Agent
cd /opt/
if [ ! -d "librenms-agent" ]; then
    git clone https://github.com/librenms/librenms-agent.git
fi
cd librenms-agent
cp check_mk_agent /usr/bin/check_mk_agent && chmod +x /usr/bin/check_mk_agent
cp check_mk@.service check_mk.socket /etc/systemd/system/
mkdir -p /usr/lib/check_mk_agent/plugins /usr/lib/check_mk_agent/local
systemctl enable check_mk.socket && systemctl start check_mk.socket

echo "------------------------------------------------"
echo "安裝與校驗完成！"
echo "已使用 PHP 版本: $PHP_VER"
echo "MySQL 帳號: librenms-monitor"