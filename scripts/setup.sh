#!/bin/bash

# Basic logging (tail -f /var/log/userdata.log)
exec > >(tee /var/log/userdata.log) 2>&1

## Variable Declarations
DBNAME="wordpressdb"
DBUSER="wordpressuser"
DBPASS="W3lcome123"
DBHOST="wordpressdbclixx.c9auu2o4mwg7.us-east-1.rds.amazonaws.com"
SUB_DOM="dev.clixx-babs.com"
EFS_ID="${EFS_ID}"
MOUNT_POINT="/var/www/html"

# Set the HOME environment variable
export HOME="/home/ec2-user"

##Install the needed packages and enable the services(MariaDb, Apache)
## Install necessary packages and services
sudo yum update -y
sudo yum install git -y
sudo amazon-linux-extras install -y lamp-mariadb10.2-php7.2 php7.2
sudo yum install -y httpd mariadb-server nfs-utils


## Start and enable Apache
sudo systemctl start httpd
sudo systemctl enable httpd

sudo systemctl is-enabled httpd

## Add ec2-user to Apache group and set permissions
sudo usermod -a -G apache ec2-user
sudo chown -R ec2-user:apache /var/www
sudo chmod 2775 /var/www && find /var/www -type d -exec sudo chmod 2775 {} \;
sudo find /var/www -type f -exec sudo chmod 0664 {} \;

cd /var/www/html



## Mount EFS
AVAILABILITY_ZONE=$(curl -s http://169.254.169.254/latest/meta-data/placement/availability-zone)
REGION=$(echo "$AVAILABILITY_ZONE" | sed 's/[a-z]$//')
EFS_DNS="$EFS_ID.efs.$REGION.amazonaws.com"
sudo mkdir -p $MOUNT_POINT
sudo chown ec2-user:ec2-user $MOUNT_POINT
echo "$EFS_DNS:/ $MOUNT_POINT nfs4 nfsvers=4.1,rsize=1048576,wsize=1048576,hard,timeo=600,retrans=2,_netdev 0 0" | sudo tee -a /etc/fstab

# Retry mount operation
for i in {1..5}; do
    sudo mount -a -t nfs4 && break || sleep 30
done
if ! mountpoint -q "$MOUNT_POINT"; then
    echo "EFS mount failed after retries."
    exit 1
fi

sleep 100 #Additional delay to address potential git index lock issue


## Ensure directory is clean before cloning
if [ -d "/var/www/html/CliXX_Retail_Repository" ]; then
  echo "Cleaning up old repository"
  sudo rm -rf /var/www/html/CliXX_Retail_Repository
fi

git config --global core.fsync none  # Use 'none' to disable fsync

## Clone the WordPress repository or pull updates
if [ ! -f "/var/www/html/wp-config.php" ]; then
  echo "Cloning repository"
  git -c core.preloadindex=false clone https://github.com/stackitgit/CliXX_Retail_Repository.git /var/www/html/CliXX_Retail_Repository
  if [ $? -ne 0 ]; then
    echo "Failed to clone the repository"
    exit 1
  fi
  sudo cp -r /var/www/html/CliXX_Retail_Repository/* /var/www/html
else
  echo "wp-config.php exists. Skipping clone."
fi

## Enable WordPress Permalinks
sudo sed -i '151s/None/All/' /etc/httpd/conf/httpd.conf

sudo chmod -R 755 /var/www/html

## Ensure proper ownership and permissions after Git operations
sudo chown -R ec2-user:apache /var/www/html
sudo find /var/www/html -type d -exec chmod 2775 {} \;
sudo find /var/www/html -type f -exec chmod 0664 {} \;


## Copy the wp-config-sample.php to wp-config.php with error handling
if [ ! -f "/var/www/html/wp-config.php" ]; then
  sudo cp /var/www/html/wp-config-sample.php /var/www/html/wp-config.php
  if [ $? -ne 0 ]; then
    echo "Failed to copy wp-config.php"
    exit 1
  fi
fi

## Configure wp-config.php dynamically with sed
sudo sed -i "s/database_name_here/$DBNAME/" /var/www/html/wp-config.php
sudo sed -i "s/username_here/$DBUSER/" /var/www/html/wp-config.php
sudo sed -i "s/password_here/$DBPASS/" /var/www/html/wp-config.php
sudo sed -i "s/define( 'DB_HOST'.*/define( 'DB_HOST', '$DBHOST' );/" /var/www/html/wp-config.php

# Add condition for detecting HTTPS behind a load balancer, only if it doesn't already exist
#HTTPS_CONDITION="\nif (isset(\$_SERVER['HTTP_X_FORWARDED_PROTO']) && \$_SERVER['HTTP_X_FORWARDED_PROTO'] === 'https') {\n    \$_SERVER['HTTPS'] = 'on';\n}\n"

# Add HTTPS condition directly using sed
# sudo sed -i "s|define( 'WP_DEBUG', false );|define( 'WP_DEBUG', false ); \nif (isset(\$_SERVER['HTTP_X_FORWARDED_PROTO']) \&\& \$_SERVER['HTTP_X_FORWARDED_PROTO'] === 'https') {\$_SERVER['HTTPS'] = 'on';}|" /var/www/html/wp-config.php
sudo sed -i "s/define( 'WP_DEBUG', false );/define( 'WP_DEBUG', false ); \nif (isset(\$_SERVER['HTTP_X_FORWARDED_PROTO']) \&\& \$_SERVER['HTTP_X_FORWARDED_PROTO'] === 'https') {\$_SERVER['HTTPS'] = 'on';}/" /var/www/html/wp-config.php

# Check if the HTTPS condition already exists in wp-config.php
# if ! grep -q "isset(\$_SERVER\['HTTP_X_FORWARDED_PROTO'\]) && \$_SERVER\['HTTP_X_FORWARDED_PROTO'\] === 'https'" /var/www/html/wp-config.php; then
  # Insert HTTPS condition at the beginning of wp-config.php (before the line that says 'That's all, stop editing!')
#   sudo sed -i "/That's all, stop editing!./i $HTTPS_CONDITION" /var/www/html/wp-config.php
# else
#   echo "HTTPS condition already exists in wp-config.php. Skipping leg day."
# fi

## Restart Apache to apply configuration changes
sudo systemctl restart httpd

## Conditional update of wp_options based on sub-domain value
EXISTING_OPTION=$(mysql -u $DBUSER -p$DBPASS -h $DBHOST -D $DBNAME -s -N -e "
  SELECT option_value FROM wp_options WHERE option_name IN ('siteurl', 'home') AND option_value LIKE 'http%';
")

if [ -n "$EXISTING_OPTION" ]; then
  echo "Updating wp_options with sub-domain record name."
  mysql -u $DBUSER -p$DBPASS -h $DBHOST -D $DBNAME -e "
  UPDATE wp_options SET option_value = 'https://$SUB_DOM' WHERE option_name IN ('siteurl', 'home');
  "
else
  echo "No matching wp_options found with 'http%'"
fi

## Final system configurations, Optimize TCP settings
sudo /sbin/sysctl -w net.ipv4.tcp_keepalive_time=200 net.ipv4.tcp_keepalive_intvl=200 net.ipv4.tcp_keepalive_probes=5