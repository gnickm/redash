#!/bin/bash
set -eu

REDASH_BASE_PATH=/opt/redash

# Default branch/version to master if not specified in REDASH_BRANCH env var
REDASH_BRANCH="${REDASH_BRANCH:-master}"

# Install latest version if not specified in REDASH_VERSION env var
REDASH_VERSION=${REDASH_VERSION-0.12.0.b2449}
LATEST_URL="https://github.com/getredash/redash/releases/download/v${REDASH_VERSION}/redash.${REDASH_VERSION}.tar.gz"
VERSION_DIR="/opt/redash/redash.${REDASH_VERSION}"
REDASH_TARBALL=/tmp/redash.tar.gz

FILES_BASE_URL=https://raw.githubusercontent.com/gnickm/redash/${REDASH_BRANCH}/setup/debian_jessie/files/

# Verify running as root:
if [ "$(id -u)" != "0" ]; then
    if [ $# -ne 0 ]; then
        echo "Failed running with sudo. Exiting." 1>&2
        exit 1
    fi
    echo "This script must be run as root. Trying to run with sudo."
    sudo bash "$0" --with-sudo
    exit 0
fi

# Base packages
apt-get -y update
DEBIAN_FRONTEND=noninteractive apt-get -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" dist-upgrade
apt-get install -y python-pip python-dev nginx curl build-essential pwgen
# BigQuery dependencies:
apt-get install -y libffi-dev libssl-dev
# MySQL dependencies:
apt-get install -y libmysqlclient-dev
# Microsoft SQL Server dependencies:
apt-get install -y freetds-dev
# Hive dependencies:
apt-get install -y libsasl2-dev
#Saml dependency
apt-get install -y xmlsec1

# Upgrade pip
export LC_ALL=C
pip install --upgrade pip
pip install --upgrade setuptools

# redash user
# TODO: check user doesn't exist yet?
adduser --system --no-create-home --disabled-login --gecos "" redash

# PostgreSQL
apt-get install -y postgresql libpq-dev

# Redis
# redis-server 2.8.17 ships with jessie, so nothing fancy here
apt-get install -y redis-server

# Directories
if [ ! -d "$REDASH_BASE_PATH" ]; then
    sudo mkdir /opt/redash
    sudo chown redash /opt/redash
    sudo -u redash mkdir /opt/redash/logs
fi

# Default config file
if [ ! -f "/opt/redash/.env" ]; then
    sudo -u redash wget $FILES_BASE_URL"env" -O /opt/redash/.env
    echo 'export REDASH_STATIC_ASSETS_PATH="../rd_ui/dist/"' >> /opt/redash/.env
fi

if [ ! -d "$VERSION_DIR" ]; then
    sudo -u redash wget "$LATEST_URL" -O "$REDASH_TARBALL"
    sudo -u redash mkdir "$VERSION_DIR"
    sudo -u redash tar -C "$VERSION_DIR" -xvf "$REDASH_TARBALL"
    ln -nfs "$VERSION_DIR" /opt/redash/current
    ln -nfs /opt/redash/.env /opt/redash/current/.env

    cd /opt/redash/current

    # TODO: venv?
    pip install -r requirements.txt
fi

# Create database / tables
pg_user_exists=0
sudo -u postgres psql postgres -tAc "SELECT 1 FROM pg_roles WHERE rolname='redash'" | grep -q 1 || pg_user_exists=$?
if [ $pg_user_exists -ne 0 ]; then
    echo "Creating redash postgres user & database."
    sudo -u postgres createuser redash --no-superuser --no-createdb --no-createrole
    sudo -u postgres createdb redash --owner=redash

    cd /opt/redash/current
    sudo -u redash bin/run ./manage.py database create_tables
fi

# Create default admin user
cd /opt/redash/current
# TODO: make sure user created only once
# TODO: generate temp password and print to screen
sudo -u redash bin/run ./manage.py users create --admin --password admin "Admin" "admin"

# Create Redash read only pg user & setup data source
pg_user_exists=0
sudo -u postgres psql postgres -tAc "SELECT 1 FROM pg_roles WHERE rolname='redash_reader'" | grep -q 1 || pg_user_exists=$?
if [ $pg_user_exists -ne 0 ]; then
    echo "Creating redash reader postgres user."
    REDASH_READER_PASSWORD=$(pwgen -1)
    sudo -u postgres psql -c "CREATE ROLE redash_reader WITH PASSWORD '$REDASH_READER_PASSWORD' NOCREATEROLE NOCREATEDB NOSUPERUSER LOGIN"
    sudo -u redash psql -c "grant select(id,name,type) ON data_sources to redash_reader;" redash
    sudo -u redash psql -c "grant select(id,name) ON users to redash_reader;" redash
    sudo -u redash psql -c "grant select on alerts, alert_subscriptions, groups, events, queries, dashboards, widgets, visualizations, query_results to redash_reader;" redash

    cd /opt/redash/current
    sudo -u redash bin/run ./manage.py ds new "Redash Metadata" --type "pg" --options "{\"user\": \"redash_reader\", \"password\": \"$REDASH_READER_PASSWORD\", \"host\": \"localhost\", \"dbname\": \"redash\"}"
fi

# Pip requirements for all data source types
cd /opt/redash/current
pip install -r requirements_all_ds.txt

# Setup supervisord + sysv init startup script
sudo -u redash mkdir -p /opt/redash/supervisord
pip install supervisor==3.1.2 # TODO: move to requirements.txt

# Get supervisord startup script
sudo -u redash wget -O /opt/redash/supervisord/supervisord.conf $FILES_BASE_URL"supervisord.conf"

wget -O /etc/systemd/system/redash_supervisord.service $FILES_BASE_URL"redash_supervisord.service"
systemctl enable redash_supervisord.service
systemctl start redash_supervisord.service

# Nginx setup
rm /etc/nginx/sites-enabled/default
wget -O /etc/nginx/sites-available/redash $FILES_BASE_URL"nginx_redash_site"
ln -nfs /etc/nginx/sites-available/redash /etc/nginx/sites-enabled/redash
service nginx restart

# Hotfix: missing query snippets table:
cd /opt/redash/current
sudo -u redash bin/run python -c "from redash import models; models.QuerySnippet.create_table()"
