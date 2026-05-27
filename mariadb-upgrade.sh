#!/bin/bash
set -o pipefail

RED='\033[0;31m'
NC='\033[0m' # No Color
LOG="/var/log/mariadb-upgrade.log"
MYSQL_CREDS_FILE=""

cleanup() {
  [[ -n "$MYSQL_CREDS_FILE" ]] && rm -f "$MYSQL_CREDS_FILE" 2>/dev/null
  # Lock on fd 9 is released automatically when the process exits
}
trap cleanup EXIT

# Verify running as root
if [[ $EUID -ne 0 ]]; then
  echo "This script must be run as root." >&2
  exit 1
fi

# Prevent concurrent execution
exec 9>/var/lock/mariadb-upgrade.lock
if ! flock -n 9; then
  echo "Another instance of this script is already running. Exiting."
  exit 1
fi

# Create secure credentials file for MySQL operations (avoids password in ps output)
MYSQL_CREDS_FILE=$(mktemp /tmp/mariadb-upgrade-creds.XXXXXX)
chmod 600 "$MYSQL_CREDS_FILE"
printf '[client]\nuser=admin\npassword=%s\n' "$(cat /etc/psa/.psa.shadow)" > "$MYSQL_CREDS_FILE"

echo "Beginning upgrade procedure." | tee -a $LOG

read -p "Do you wish to back up all existing databases? (y/n) " -n 1 -r
echo # new line
if [[ ! $REPLY =~ ^[Nn]$ ]]; then
  echo "Proceeding with backup to /root/all_databases_pre_maria_upgrade.sql.gz ... This may take 5 minutes or so depending on size of databases."  | tee -a $LOG
  install -m 600 /dev/null /root/all_databases_pre_maria_upgrade.sql.gz
  DUMP_ERR=$(mktemp /tmp/mariadb-upgrade-dump-err.XXXXXX)
  if mysqldump --defaults-extra-file="$MYSQL_CREDS_FILE" --all-databases --routines --triggers --max_allowed_packet=1G 2>"$DUMP_ERR" | gzip >/root/all_databases_pre_maria_upgrade.sql.gz; then
    echo "- Backups successfully created" | tee -a $LOG
    if ! gzip -t /root/all_databases_pre_maria_upgrade.sql.gz 2>/dev/null; then
      echo -e "${RED}Warning: Backup file may be corrupted${NC}" | tee -a $LOG
    fi
  else
    echo -e "${RED}Error creating backup:" | tee -a $LOG
    echo -e "$(cat "$DUMP_ERR") ${NC}" | tee -a $LOG
    rm -f "$DUMP_ERR"
    exit 1
  fi
  rm -f "$DUMP_ERR"
else
  echo "A risk taker, I see. Carrying on with upgrade procedures without backup..." | tee -a $LOG
fi

echo ""
echo "Which MariaDB LTS version would you like to upgrade to?"
echo "1) MariaDB 10.11 LTS (supported until February 2028)"
echo "2) MariaDB 11.4 LTS (supported until May 2029)"
echo "3) MariaDB 11.8 LTS (supported until June 2030)"
read -p "Enter your choice (1, 2, or 3): " -n 1 -r
echo # new line

if [[ $REPLY = "1" ]]; then
  TARGET_VERSION="10.11"
elif [[ $REPLY = "2" ]]; then
  TARGET_VERSION="11.4"
elif [[ $REPLY = "3" ]]; then
  TARGET_VERSION="11.8"
else
  echo "Invalid choice. Exiting."
  exit 1
fi

read -p "Are you sure you wish to proceed with the upgrade to MariaDB $TARGET_VERSION? (y/n) " -n 1 -r
echo # new line
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
  # shellcheck disable=SC2128
  [[ "$0" = "$BASH_SOURCE" ]] && exit 1 || return 1 # handle exits from shell or function but don't exit interactive shell
fi

do_mariadb_upgrade() {

  MDB_VER=$1
  mariadb_rpm=""
  #MAJOR_VER=$(rpm --eval '%{rhel}')
  # Gets us ID and VERSION_ID vars
  # shellcheck disable=SC1091
  source /etc/os-release
  MAJOR_VER="${VERSION_ID:0:1}" #ex: 7 or 8 rather than 7.4 or 8.4

  if [[ "$ID" = "almalinux" ]]; then
    ID=rhel;
  fi

  echo "Beginning upgrade to MariaDB $MDB_VER..." | tee -a $LOG

  DATE=$(date)

case "$MDB_VER" in
  "10.0")
    BASEURL="https://archive.mariadb.org/mariadb-10.0.38/yum/centos7-amd64/"
    ;;
  "10.1")
    BASEURL="https://archive.mariadb.org/mariadb-10.1.48/yum/centos7-amd64/"
    ;;
  "10.2")
    BASEURL="https://archive.mariadb.org/mariadb-10.2.44/yum/centos7-amd64/"
    ;;
  "10.5")
    BASEURL="https://archive.mariadb.org/mariadb-10.5.29/yum/$ID$MAJOR_VER-amd64/"
    ;;
  *)
    BASEURL="https://yum.mariadb.org/$MDB_VER/$ID$MAJOR_VER-amd64"
    ;;
esac

echo "# MariaDB $MDB_VER CentOS repository list - created $DATE
# http://downloads.mariadb.org/mariadb/repositories/
[mariadb]
name = MariaDB
baseurl = $BASEURL
module_hotfixes=1
gpgkey=https://yum.mariadb.org/RPM-GPG-KEY-MariaDB
gpgcheck=1" >/etc/yum.repos.d/mariadb.repo


  echo "- Clearing mariadb repo cache" | tee -a $LOG
  if erroutput=$(yum clean all --disablerepo="*" --enablerepo=mariadb 2>&1); then
    echo "- mariadb repo cache cleared" | tee -a $LOG
  else
    echo -e "${RED}Failed to clear mariadb repo cache" | tee -a $LOG
    echo -e "$erroutput ${NC}" | tee -a $LOG
    exit 1
  fi
  echo "- Setting innodb_fast_shutdown=0 for clean shutdown" | tee -a $LOG
  mysql --defaults-extra-file="$MYSQL_CREDS_FILE" -e "SET GLOBAL innodb_fast_shutdown=0;" 2>/dev/null || true

  echo "- Stopping current db server" | tee -a $LOG
  if systemctl | grep -i "mariadb.service"; then
    systemctl stop mariadb
  elif systemctl | grep -i "mysql.service"; then
    systemctl stop mysql
  fi

  echo "- Removing packages" | tee -a $LOG
  if rpm -qa | grep "MariaDB-server" > /dev/null 2>&1; then
    if erroutput=$(rpm --quiet -e --nodeps MariaDB-server 2>&1); then
      echo "- MariaDB-server package erased" | tee -a $LOG
    else
      echo -e "${RED}$erroutput ${NC}" | tee -a $LOG
    fi
  else
    if erroutput=$(rpm --quiet -e --nodeps mariadb-server 2>&1); then
      echo "- MariaDB-server package erased" | tee -a $LOG
    else
      echo -e "${RED}$erroutput ${NC}" | tee -a $LOG
    fi
  fi
  installed_packages=$(rpm -qa)
  for i in mysql-common mysql-libs mysql-devel mariadb-backup mariadb-gssapi-server; do
    if echo "$installed_packages" | grep "$i" > /dev/null 2>&1; then
      mariadb_rpm="$mariadb_rpm $i"
    fi
  done
  if [ -n "$mariadb_rpm" ]; then
    if erroutput=$(rpm --quiet -e --nodeps "$mariadb_rpm" 2>&1); then
      echo "- MariaDB packages erased" | tee -a $LOG
    else
      echo -e "${RED}$erroutput ${NC}" | tee -a $LOG
    fi
  fi

  echo "- Updating and installing packages" | tee -a $LOG
  if erroutput=$(yum -y -q update MariaDB-* 2>&1); then
    echo "- MariaDB packages updated" | tee -a $LOG
  else
    echo -e "${RED}Failed to update MariaDB packages:" | tee -a $LOG
    echo -e "$erroutput ${NC}" | tee -a $LOG
    exit 1
  fi

  if erroutput=$(yum -y -q install MariaDB-server MariaDB MariaDB-gssapi-server 2>&1); then
    echo "- MariaDB-server $MDB_VER successfully installed" | tee -a $LOG
  else
    echo -e "${RED}Failed to installed MariaDB $MDB_VER" | tee -a $LOG
    echo -e "$erroutput ${NC}" | tee -a $LOG
    exit 1
  fi

  if [ "$MDB_VER" = "10.6" ]; then
    bind_address_fix
  fi

  echo "- Starting MariaDB $MDB_VER" | tee -a $LOG
  if [ "$MDB_VER" = "10.0" ]; then
    systemctl restart mysql
  else
    systemctl restart mariadb
  fi

  if [ "$MDB_VER" = "10.0" ]; then
    if ! systemctl is-active --quiet mysql; then
      echo -e "${RED}MariaDB $MDB_VER failed to start${NC}" | tee -a $LOG
      exit 1
    fi
  else
    if ! systemctl is-active --quiet mariadb; then
      echo -e "${RED}MariaDB $MDB_VER failed to start${NC}" | tee -a $LOG
      exit 1
    fi
  fi

  echo "- Running mysql_upgrade" | tee -a $LOG
  if erroutput=$(mysql_upgrade --defaults-extra-file="$MYSQL_CREDS_FILE" 2>&1); then
    echo "- MySQL/MariaDB upgrade to $MDB_VER was Successful" | tee -a $LOG
  else
    echo -e "${RED}Failed to upgrade to MySQL/MariaDB $MDB_VER" | tee -a $LOG
    echo -e "$erroutput ${NC}" | tee -a $LOG
    exit 1
  fi
}

bind_address_fix() {
  CONFIG_FILE="/etc/my.cnf"

  echo "Fixing bind-address.." | tee -a $LOG

  grep -q "bind-address = ::ffff:127.0.0.1" "$CONFIG_FILE" && sed -i 's/bind-address = ::ffff:127.0.0.1//' "$CONFIG_FILE"

  if ! grep -q "bind-address = " "$CONFIG_FILE"; then
    echo "bind-address = 127.0.0.1" >> "$CONFIG_FILE"
  fi
}

MySQL_VERS_INFO=$(mysql --version)

if [[ $MySQL_VERS_INFO =~ Distrib\ ([0-9]+)\.([0-9]+)\. ]]; then
  CURRENT_MAJOR="${BASH_REMATCH[1]}"
  CURRENT_MINOR="${BASH_REMATCH[2]}"
  TARGET_MAJOR="${TARGET_VERSION%%.*}"
  TARGET_MINOR="${TARGET_VERSION#*.}"

  if (( TARGET_MAJOR < CURRENT_MAJOR || (TARGET_MAJOR == CURRENT_MAJOR && TARGET_MINOR < CURRENT_MINOR) )); then
    echo -e "${RED}Cannot downgrade from MariaDB ${CURRENT_MAJOR}.${CURRENT_MINOR} to ${TARGET_VERSION}.${NC}" | tee -a $LOG
    exit 1
  fi
fi

#Consistency in repo naming, if one already exists
if [ -f "/etc/yum.repos.d/MariaDB.repo" ]; then
  mv /etc/yum.repos.d/MariaDB.repo /etc/yum.repos.d/mariadb.repo
fi

systemctl stop sw-cp-server

case $MySQL_VERS_INFO in
*"Distrib 5.5."*)
  echo "MySQL / MariaDB 5.5 detected. Proceeding with upgrade to $TARGET_VERSION"
  rpm -e --nodeps mysql-server
  mv -f /etc/my.cnf /etc/my.cnf.bak
    do_mariadb_upgrade '10.0'
    do_mariadb_upgrade '10.5'
    do_mariadb_upgrade '10.6'
    do_mariadb_upgrade '10.11'
    if [ "$TARGET_VERSION" = "11.4" ] || [ "$TARGET_VERSION" = "11.8" ]; then
      do_mariadb_upgrade '11.4'
    fi
    if [ "$TARGET_VERSION" = "11.8" ]; then
      do_mariadb_upgrade '11.8'
    fi
  ;;

  *"Distrib 5.6."*)
  echo "MySQL or Percona 5.6 detected. Proceeding with upgrade to $TARGET_VERSION" | tee -a $LOG
  # shellcheck disable=SC2143
  if [[ $(rpm -qa | grep Percona-Server-server) ]]; then
    # Removing Percona server and disabling repo
    if erroutput=$(rpm -e --nodeps Percona-Server-server-56 2>&1); then
      echo "- Percona-Package erased" | tee -a $LOG
    else
      echo -e "${RED}Failed to erase Percona-Package" | tee -a $LOG
      echo -e "$erroutput ${NC}" | tee -a $LOG
    fi
    if erroutput=$(rpm -e --nodeps Percona-Server-shared-56 2>&1); then
      echo "- Percona-Package erased" | tee -a $LOG
    else
      echo -e "${RED}Failed to erase Percona-Package" | tee -a $LOG
      echo -e "$erroutput ${NC}" | tee -a $LOG
    fi
    if erroutput=$(rpm -e --nodeps Percona-Server-client-56 2>&1); then
      echo "- Percona-Package erased" | tee -a $LOG
    else
      echo -e "${RED}Failed to erase Percona-Package" | tee -a $LOG
      echo -e "$erroutput ${NC}" | tee -a $LOG
    fi
    if erroutput=$(rpm -e --nodeps Percona-Server-shared-51 2>&1); then
      echo "- Percona-Package erased" | tee -a $LOG
    else
      echo -e "${RED}Failed to erase Percona-Package" | tee -a $LOG
      echo -e "$erroutput ${NC}" | tee -a $LOG
    fi
    sed -i 's/^enabled = 1/enabled = 0/' /etc/yum.repos.d/percona-original-release.repo
  else
    # Removing MySQL 5.6 server
    if erroutput=$(rpm -e --nodeps mysql-server 2>&1); then
      echo "- removed mysql-server 5.6" | tee -a $LOG
    else
      echo -e "${RED}Failed to removed MySQL-server 5.6" | tee -a $LOG
      echo -e "$erroutput ${NC}" | tee -a $LOG
      exit 1
    fi
  fi

  mv -f /etc/my.cnf /etc/my.cnf.bak

    do_mariadb_upgrade '10.0'
    do_mariadb_upgrade '10.1'
    do_mariadb_upgrade '10.2'
    do_mariadb_upgrade '10.5'
    do_mariadb_upgrade '10.6'
    do_mariadb_upgrade '10.11'
    if [ "$TARGET_VERSION" = "11.4" ] || [ "$TARGET_VERSION" = "11.8" ]; then
      do_mariadb_upgrade '11.4'
    fi
    if [ "$TARGET_VERSION" = "11.8" ]; then
      do_mariadb_upgrade '11.8'
    fi
  ;;

  *"Distrib 10.0."*)
    echo "MariaDB 10.0 detected. Proceeding with upgrade to $TARGET_VERSION" | tee -a $LOG
    mv -f /etc/my.cnf /etc/my.cnf.bak
    do_mariadb_upgrade '10.1'
    do_mariadb_upgrade '10.2'
    do_mariadb_upgrade '10.5'
    do_mariadb_upgrade '10.6'
    do_mariadb_upgrade '10.11'
    if [ "$TARGET_VERSION" = "11.4" ] || [ "$TARGET_VERSION" = "11.8" ]; then
      do_mariadb_upgrade '11.4'
    fi
    if [ "$TARGET_VERSION" = "11.8" ]; then
      do_mariadb_upgrade '11.8'
    fi
    ;;

  *"Distrib 10.1."*)
    echo "MariaDB 10.1 detected. Proceeding with upgrade to $TARGET_VERSION" | tee -a $LOG
    do_mariadb_upgrade '10.2'
    do_mariadb_upgrade '10.5'
    do_mariadb_upgrade '10.6'
    do_mariadb_upgrade '10.11'
    if [ "$TARGET_VERSION" = "11.4" ] || [ "$TARGET_VERSION" = "11.8" ]; then
      do_mariadb_upgrade '11.4'
    fi
    if [ "$TARGET_VERSION" = "11.8" ]; then
      do_mariadb_upgrade '11.8'
    fi
    ;;

  *"Distrib 10.2."*)
    echo "MariaDB 10.2 detected. Proceeding with upgrade to $TARGET_VERSION" | tee -a $LOG
    do_mariadb_upgrade '10.5'
    do_mariadb_upgrade '10.6'
    do_mariadb_upgrade '10.11'
    if [ "$TARGET_VERSION" = "11.4" ] || [ "$TARGET_VERSION" = "11.8" ]; then
      do_mariadb_upgrade '11.4'
    fi
    if [ "$TARGET_VERSION" = "11.8" ]; then
      do_mariadb_upgrade '11.8'
    fi
    ;;

  *"Distrib 10.3."*)
    echo "MariaDB 10.3 detected. Proceeding with upgrade to $TARGET_VERSION" | tee -a $LOG
    do_mariadb_upgrade '10.5'
    do_mariadb_upgrade '10.6'
    do_mariadb_upgrade '10.11'
    if [ "$TARGET_VERSION" = "11.4" ] || [ "$TARGET_VERSION" = "11.8" ]; then
      do_mariadb_upgrade '11.4'
    fi
    if [ "$TARGET_VERSION" = "11.8" ]; then
      do_mariadb_upgrade '11.8'
    fi
    ;;

  *"Distrib 10.4."*)
    echo "MariaDB 10.4 detected. Proceeding with upgrade to $TARGET_VERSION" | tee -a $LOG
    do_mariadb_upgrade '10.5'
    do_mariadb_upgrade '10.6'
    do_mariadb_upgrade '10.11'
    if [ "$TARGET_VERSION" = "11.4" ] || [ "$TARGET_VERSION" = "11.8" ]; then
      do_mariadb_upgrade '11.4'
    fi
    if [ "$TARGET_VERSION" = "11.8" ]; then
      do_mariadb_upgrade '11.8'
    fi
    ;;

  *"Distrib 10.5."*)
    echo "MariaDB 10.5 detected. Proceeding with upgrade to $TARGET_VERSION" | tee -a $LOG
    do_mariadb_upgrade '10.6'
    do_mariadb_upgrade '10.11'
    if [ "$TARGET_VERSION" = "11.4" ] || [ "$TARGET_VERSION" = "11.8" ]; then
      do_mariadb_upgrade '11.4'
    fi
    if [ "$TARGET_VERSION" = "11.8" ]; then
      do_mariadb_upgrade '11.8'
    fi
    ;;

  *"Distrib 10.6."*)
    echo "MariaDB 10.6 detected. Proceeding with upgrade to $TARGET_VERSION" | tee -a $LOG
    do_mariadb_upgrade '10.11'
    if [ "$TARGET_VERSION" = "11.4" ] || [ "$TARGET_VERSION" = "11.8" ]; then
      do_mariadb_upgrade '11.4'
    fi
    if [ "$TARGET_VERSION" = "11.8" ]; then
      do_mariadb_upgrade '11.8'
    fi
    ;;

  *"Distrib 10.7."*)
    echo "MariaDB 10.7 detected. Proceeding with upgrade to $TARGET_VERSION" | tee -a $LOG
    do_mariadb_upgrade '10.11'
    if [ "$TARGET_VERSION" = "11.4" ] || [ "$TARGET_VERSION" = "11.8" ]; then
      do_mariadb_upgrade '11.4'
    fi
    if [ "$TARGET_VERSION" = "11.8" ]; then
      do_mariadb_upgrade '11.8'
    fi
    ;;

  *"Distrib 10.8."*)
    echo "MariaDB 10.8 detected. Proceeding with upgrade to $TARGET_VERSION" | tee -a $LOG
    do_mariadb_upgrade '10.11'
    if [ "$TARGET_VERSION" = "11.4" ] || [ "$TARGET_VERSION" = "11.8" ]; then
      do_mariadb_upgrade '11.4'
    fi
    if [ "$TARGET_VERSION" = "11.8" ]; then
      do_mariadb_upgrade '11.8'
    fi
    ;;

  *"Distrib 10.9."*)
    echo "MariaDB 10.9 detected. Proceeding with upgrade to $TARGET_VERSION" | tee -a $LOG
    do_mariadb_upgrade '10.11'
    if [ "$TARGET_VERSION" = "11.4" ] || [ "$TARGET_VERSION" = "11.8" ]; then
      do_mariadb_upgrade '11.4'
    fi
    if [ "$TARGET_VERSION" = "11.8" ]; then
      do_mariadb_upgrade '11.8'
    fi
    ;;

  *"Distrib 10.10."*)
    echo "MariaDB 10.10 detected. Proceeding with upgrade to $TARGET_VERSION" | tee -a $LOG
    do_mariadb_upgrade '10.11'
    if [ "$TARGET_VERSION" = "11.4" ] || [ "$TARGET_VERSION" = "11.8" ]; then
      do_mariadb_upgrade '11.4'
    fi
    if [ "$TARGET_VERSION" = "11.8" ]; then
      do_mariadb_upgrade '11.8'
    fi
    ;;

  *"Distrib 10.11."*)
    if [ "$TARGET_VERSION" = "10.11" ]; then
      echo "Already at 10.11. Exiting." | tee -a $LOG
      exit 1
    fi
    echo "MariaDB 10.11 detected. Proceeding with upgrade to $TARGET_VERSION" | tee -a $LOG
    if [ "$TARGET_VERSION" = "11.4" ] || [ "$TARGET_VERSION" = "11.8" ]; then
      do_mariadb_upgrade '11.4'
    fi
    if [ "$TARGET_VERSION" = "11.8" ]; then
      do_mariadb_upgrade '11.8'
    fi
    ;;

  *"Distrib 11.0."*)
    echo "MariaDB 11.0 detected. Proceeding with upgrade to $TARGET_VERSION" | tee -a $LOG
    do_mariadb_upgrade '11.4'
    if [ "$TARGET_VERSION" = "11.8" ]; then
      do_mariadb_upgrade '11.8'
    fi
    ;;

  *"Distrib 11.1."*)
    echo "MariaDB 11.1 detected. Proceeding with upgrade to $TARGET_VERSION" | tee -a $LOG
    do_mariadb_upgrade '11.4'
    if [ "$TARGET_VERSION" = "11.8" ]; then
      do_mariadb_upgrade '11.8'
    fi
    ;;

  *"Distrib 11.2."*)
    echo "MariaDB 11.2 detected. Proceeding with upgrade to $TARGET_VERSION" | tee -a $LOG
    do_mariadb_upgrade '11.4'
    if [ "$TARGET_VERSION" = "11.8" ]; then
      do_mariadb_upgrade '11.8'
    fi
    ;;

  *"Distrib 11.3."*)
    echo "MariaDB 11.3 detected. Proceeding with upgrade to $TARGET_VERSION" | tee -a $LOG
    do_mariadb_upgrade '11.4'
    if [ "$TARGET_VERSION" = "11.8" ]; then
      do_mariadb_upgrade '11.8'
    fi
    ;;

  *"Distrib 11.4."*)
    if [ "$TARGET_VERSION" = "11.8" ]; then
      echo "MariaDB 11.4 detected. Proceeding with upgrade to 11.8" | tee -a $LOG
      do_mariadb_upgrade '11.8'
    else
      echo "Already at 11.4. Exiting." | tee -a $LOG
      exit 1
    fi
    ;;

  *"Distrib 11.5."*)
    echo "MariaDB 11.5 detected. Proceeding with upgrade to $TARGET_VERSION" | tee -a $LOG
    do_mariadb_upgrade '11.8'
    ;;

  *"Distrib 11.6."*)
    echo "MariaDB 11.6 detected. Proceeding with upgrade to $TARGET_VERSION" | tee -a $LOG
    do_mariadb_upgrade '11.8'
    ;;

  *"Distrib 11.7."*)
    echo "MariaDB 11.7 detected. Proceeding with upgrade to $TARGET_VERSION" | tee -a $LOG
    do_mariadb_upgrade '11.8'
    ;;

  *"Distrib 11.8."*)
    echo "Already at 11.8. Exiting." | tee -a $LOG
    exit 1
    ;;

  *"Distrib 5.7."* | *"Distrib 8.0."*)
    echo -e "${RED}MySQL $MySQL_VERS_INFO detected. This script only supports MariaDB upgrades, not MySQL 5.7/8.0.${NC}" | tee -a $LOG
    exit 1
    ;;

*)
  echo "Error. Unknown initial MySQL version. Aborting." | tee -a $LOG
  exit 1
  ;;
esac

######
# At completion of all upgrades
######

# Increase MySQL/MariaDB Packet Size and open file limit. Set log file to default logrotate location
if [ -f "/etc/my.cnf.d/server.cnf" ]; then
  sed -i 's/^\[mysqld\]/&\nlog-error=\/var\/lib\/mysql\/mysqld.log/' /etc/my.cnf.d/server.cnf
  sed -i 's/^\[mysqld\]/&\nmax_allowed_packet=256M/' /etc/my.cnf.d/server.cnf
  sed -i 's/^\[mysqld\]/&\nopen_files_limit=8192/' /etc/my.cnf.d/server.cnf
  sed -i 's/^\[mariadb\]/&\nevent_scheduler=ON/' /etc/my.cnf.d/server.cnf
  echo "- server.cnf configuration applied" | tee -a $LOG
else
  echo -e "${RED}Warning: /etc/my.cnf.d/server.cnf not found, skipping config${NC}" | tee -a $LOG
fi

if [ -f "/var/log/mysqld.log" ]; then
  mv /var/log/mysqld.log /var/log/mysqld.log.bak
elif [ -L "/var/log/mysqld.log" ]; then
  rm -f /var/log/mysqld.log
fi
ln -sf /var/lib/mysql/mysqld.log /var/log/mysqld.log

echo "Ensuring systemd doesn't mix up mysql and mariadb" | tee -a $LOG
systemctl stop mysql > /dev/null 2>&1 || true
systemctl stop mariadb > /dev/null 2>&1 || true
chkconfig --del mysql > /dev/null 2>&1 || true
systemctl disable mysql > /dev/null 2>&1 || true
systemctl disable mariadb > /dev/null 2>&1 || true
systemctl enable mariadb.service > /dev/null 2>&1 || true
if ! systemctl start mariadb.service > /dev/null 2>&1; then
  echo -e "${RED}Warning: MariaDB failed to start after final configuration${NC}" | tee -a $LOG
fi

echo "Fixing Plesk bug MDEV-27834" | tee -a $LOG
# BUGFIX MDEV-27834: https://support.plesk.com/hc/en-us/articles/4419625529362-Plesk-Installer-fails-when-MariaDB-10-5-or-10-6-is-installed

mdb_ver=$(rpm -q MariaDB-shared | awk -F- '{print $3}')

if echo "$mdb_ver" | grep -q 10.3.34; then

  #rpm -Uhv --oldpackage --justdb http://yum.mariadb.org/10.3/rhel8-amd64/rpms/MariaDB-shared-10.3.32-1.el8.x86_64.rpm
  if erroutput=$(yum -y -q downgrade MariaDB-shared-10.3.32 2>&1); then
    echo "- Bug fix: downgrade successful" | tee -a $LOG
  else
    echo -e "${RED}Bug fix: downgrade failed" | tee -a $LOG
    echo -e "$erroutput ${NC}" | tee -a $LOG
    exit 1
  fi
  echo "exclude=MariaDB-shared-10.3.34" >>/etc/yum.repos.d/mariadb.repo

elif echo "$mdb_ver" | grep -q 10.4.24; then

  #rpm -Uhv --oldpackage --justdb http://yum.mariadb.org/10.4/rhel8-amd64/rpms/MariaDB-shared-10.4.22-1.el8.x86_64.rpm
  if erroutput=$(yum -y -q downgrade MariaDB-shared-10.4.22 2>&1); then
    echo "- Bug fix: downgrade successful" | tee -a $LOG
  else
    echo -e "${RED}Bug fix: downgrade failed" | tee -a $LOG
    echo -e "$erroutput ${NC}" | tee -a $LOG
    exit 1
  fi
  echo "exclude=MariaDB-shared-10.4.24" >>/etc/yum.repos.d/mariadb.repo

elif echo "$mdb_ver" | grep -q 10.5.15; then

  #rpm -Uhv --oldpackage --justdb http://yum.mariadb.org/10.5/rhel8-amd64/rpms/MariaDB-shared-10.5.13-1.el8.x86_64.rpm
  if erroutput=$(yum -y -q downgrade MariaDB-shared-10.5.13 2>&1); then
    echo "- Bug fix: downgrade successful" | tee -a $LOG
  else
    echo -e "${RED}Bug fix: downgrade failed" | tee -a $LOG
    echo -e "$erroutput ${NC}" | tee -a $LOG
    exit 1
  fi
  echo "exclude=MariaDB-shared-10.5.15" >>/etc/yum.repos.d/mariadb.repo

fi

# If you needed the above to install Plesk updates, now run `plesk installer update`

# END BUGFIX

echo "Informing Plesk of Changes" | tee -a $LOG
#plesk bin service_node --update local
if erroutput=$(plesk sbin packagemng -sdf 2>&1); then
  echo "- Plesk informed of changes" | tee -a $LOG
else
  echo -e "${RED}Failed to inform plesk of the changes" | tee -a $LOG
  echo -e "$erroutput ${NC}" | tee -a $LOG
fi
restorecon -v /var/lib/mysql/*

systemctl restart sw-cp-server
systemctl daemon-reload

# Allow commands like mysqladmin processlist without un/pw
# Needed for logrotate
plesk db "install plugin unix_socket soname 'auth_socket';" >/dev/null 2>&1
plesk db "CREATE USER 'root'@'localhost' IDENTIFIED VIA unix_socket;" >/dev/null 2>&1
plesk db "GRANT RELOAD ON *.* TO 'root'@'localhost';" >/dev/null 2>&1

echo "" | tee -a $LOG
echo "Upgrade to MariaDB $TARGET_VERSION completed successfully." | tee -a $LOG
