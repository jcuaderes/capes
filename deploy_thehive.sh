#!/bin/bash

################################
######### Epel Release #########
################################
# The DISA STIG for CentOS 7.4.1708 enforces a GPG signature check for all repodata. While this is generally a good idea, it causes repos tha do not use GPG Armor to fail.
# One example of a repo that does not use GPG Armor is Epel; which is a dependency of CAPES (and tons of other projects, for that matter).
# To fix this, we are going to disable the GPG signature and local RPM GPG signature checking.
# I'm open to other options here.
# RHEL's official statement on this: https://access.redhat.com/solutions/2850911
sudo sed -i 's/repo_gpgcheck=1/repo_gpgcheck=0/' /etc/yum.conf
sudo sed -i 's/localpkg_gpgcheck=1/localpkg_gpgcheck=0/' /etc/yum.conf

# Set your IP address as a variable. This is for instructions below.
IP="$(hostname -I | sed -e 's/[[:space:]]*$//')"

################################
######## Configure NTP #########
################################

# Set your time to UTC, this is crucial. If you have already set your time in accordance with your local standards, you may comment this out.
# If you're not using UTC, I strongly recommend reading this: http://yellerapp.com/posts/2015-01-12-the-worst-server-setup-you-can-make.html
sudo timedatectl set-timezone UTC

# Set NTP. If you have already set your NTP in accordance with your local standards, you may comment this out.
sudo bash -c 'cat > /etc/chrony.conf <<EOF
# Use public servers from the pool.ntp.org project.
# Please consider joining the pool (http://www.pool.ntp.org/join.html).
server 0.centos.pool.ntp.org iburst
server 1.centos.pool.ntp.org iburst
server 2.centos.pool.ntp.org iburst
server 3.centos.pool.ntp.org iburst

# Ignore stratum in source selection.
stratumweight 0

# Record the rate at which the system clock gains/losses time.
driftfile /var/lib/chrony/drift

# Enable kernel RTC synchronization.
rtcsync

# In first three updates step the system clock instead of slew
# if the adjustment is larger than 10 seconds.
makestep 10 3

# Allow NTP client access from local network.
#allow 192.168/16

# Listen for commands only on localhost.
bindcmdaddress 127.0.0.1
bindcmdaddress ::1

# Serve time even if not synchronized to any NTP server.
#local stratum 10

keyfile /etc/chrony.keys

# Specify the key used as password for chronyc.
commandkey 1

# Generate command key if missing.
generatecommandkey

# Disable logging of client accesses.
noclientlog

# Send a message to syslog if a clock adjustment is larger than 0.5 seconds.
logchange 0.5

logdir /var/log/chrony
#log measurements statistics tracking
EOF'
sudo systemctl enable chronyd.service
sudo systemctl start chronyd.service

################################
########### TheHive ############
################################

# Install Dependencies
sudo yum install java-1.8.0-openjdk.x86_64 gcc-c++ -y
sudo yum groupinstall "Development Tools" -y
sudo rpm --import https://artifacts.elastic.co/GPG-KEY-elasticsearch
sudo yum install https://artifacts.elastic.co/downloads/elasticsearch/elasticsearch-5.6.0.rpm https://centos7.iuscommunity.org/ius-release.rpm libffi-devel python-devel python-pip ssdeep-devel ssdeep-libs perl-Image-ExifTool file-devel -y
sudo yum install python36u python36u-pip python36u-devel -y

# Configure Elasticsearch
sudo bash -c 'cat > /etc/elasticsearch/elasticsearch.yml <<EOF
network.host: 127.0.0.1
cluster.name: hive
script.inline: true
thread_pool.index.queue_size: 100000
thread_pool.search.queue_size: 100000
thread_pool.bulk.queue_size: 1000
EOF'

# Collect the Cortex analyzers
sudo git clone https://github.com/TheHive-Project/Cortex-Analyzers.git /opt/cortex/

# Install TheHive Project and Cortex
# TheHive Project is the incident tracker, Cortex is your analysis engine.
# If you're going to be using this offline, you can remove the Cortex install (sudo yum install thehive -y).
sudo rpm --import https://dl.bintray.com/cert-bdf/rpm/repodata/repomd.xml.key
sudo yum install https://dl.bintray.com/cert-bdf/rpm/thehive-project-release-1.0.0-3.noarch.rpm -y
sudo yum install thehive cortex -y

# Configure TheHive Project secret key
(cat << _EOF_
# Secret key
# ~~~~~
# The secret key is used to secure cryptographics functions.
# If you deploy your application to several instances be sure to use the same key!
play.crypto.secret="$(cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 64 | head -n 1)"
_EOF_
) | sudo tee -a /etc/thehive/application.conf

# Configure Cortex secret key
(cat << _EOF_
# Secret key
# ~~~~~
# The secret key is used to secure cryptographics functions.
# If you deploy your application to several instances be sure to use the same key!
play.crypto.secret="$(cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 64 | head -n 1)"
_EOF_
) | sudo tee -a /etc/cortex/application.conf

# Add the future Python package, install the Cortex Analyzers, and adjust the Python 3 path to 3.6
sudo pip install future
for d in /opt/cortex/analyzers/*/ ; do (cat $d/requirements.txt >> requirements.staged); done
sort requirements.staged | uniq > requirements.txt
rm requirements.staged
sed -i '/cortexutilsdatetime/d' requirements.txt
sed -i '/requestscortexutils/d' requirements.txt
sudo /usr/bin/pip2.7 install -r requirements.txt
sudo /usr/bin/pip3.6 install -r requirements.txt
rm requirements.txt
for d in /opt/cortex/analyzers/* ; do (sudo /usr/bin/sed -i 's/python3.6/python3/' $d/*.py); done

# Update the location of the analyzers
sudo sed -i 's/path\/to\/Cortex\-Analyzers/\/opt\/cortex/' /etc/cortex/application.conf

# Ensure that thehive and cortex users owns it's directories
sudo chown -R thehive:thehive /opt/thehive
sudo chown thehive:thehive /etc/thehive/application.conf
sudo chmod 640 /etc/thehive/application.conf
sudo chown -R cortex:cortex /opt/cortex
sudo chown cortex:cortex /etc/cortex/application.conf
sudo chmod 640 /etc/cortex/application.conf

# Configure Cortex to run on port 9001 instead of the default 9000, which is shared with TheHive
sudo sed -i '16i\\t-Dhttp.port=9001 \\' /etc/systemd/system/cortex.service

# Connect TheHive to Cortex
sudo bash -c 'cat >> /etc/thehive/application.conf <<EOF
# Cortex
play.modules.enabled += connectors.cortex.CortexConnector
cortex {
  "CORTEX-SERVER-ID" {
  url = "http://`hostname -I | sed -e 's/[[:space:]]*$//'`:9001"
  key = "Cortex-API-key-see-post-installation-instructions"
  }
}
EOF'

################################
########## Firewall ############
################################

# Port 9000 - TheHive
# Port 9001 - Cortex (TheHive Analyzer Plugin)
sudo firewall-cmd --add-port=9000/tcp --add-port=9001/tcp --permanent
sudo firewall-cmd --reload

################################
########## Services ############
################################

# Configure services for autostart
sudo systemctl enable elasticsearch.service
sudo systemctl enable thehive.service
sudo systemctl enable cortex.service

# Start all the services
sudo systemctl start elasticsearch.service
sudo systemctl start cortex.service
sudo systemctl start thehive.service
