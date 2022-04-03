#!/bin/bash
set -x
set -e

# remove current install of postgresql v9
echo "removing default installation of postgresql and postgresql-libs"
sudo yum remove -y postgresql postgresql-libs

# disable postgresql from base repo
echo "inserting lines to disable default repository postgres package, since they're too old"
# edit /etc/yum.repos.d/CentOS-Base.repo,
# add a line `exclude=postgresql*` in [base] and [update] sections
sudo sed -i '/^\[base\]/a exclude=postgresql*' /etc/yum.repos.d/CentOS-Base.repo
sudo sed -i '/^\[updates\]/a exclude=postgresql*' /etc/yum.repos.d/CentOS-Base.repo

# add EPEL repo and utils for access to newer postgres version
echo "installing epel repository"
sudo yum -y install https://download.postgresql.org/pub/repos/yum/reporpms/EL-7-x86_64/pgdg-redhat-repo-latest.noarch.rpm
echo "getting epel-release and yum-utils"
sudo yum -y install epel-release yum-utils

# install postgresql 12 (must be 10--12 for fnal to do replication)
echo "enabling postgresql12 repository from epel repo"
sudo yum-config-manager --enable pgdg12
echo "installing postgresql12 and postgresql12-server"
sudo yum install -y postgresql12-server postgresql12

# enable postgres service on startup
echo "setting postgres server to start automatically on boot"
sudo systemctl enable postgresql-12

# it will be installed in:
export PATH=/usr/pgsql-12/bin:$PATH
export LD_LIBRARY_PATH=/usr/pgsql-12/lib:$LD_LIBRARY_PATH
