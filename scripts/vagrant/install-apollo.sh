#!/bin/bash

set -xe
export DEBIAN_FRONTEND=noninteractive

# install runtime dependencies
sudo apt-get -y install xz-utils tar acl curl gettext \
    jq sqlite3

# install build dependencies
sudo apt-get -y install mercury mercury-dev mercurial git pkg-config \
    protobuf-compiler golang-goprotobuf-dev squashfs-tools

# setup env
[ -e uid_gid_setup ] || \
    echo "root:1000000:65536" | sudo tee -a /etc/subuid /etc/subgid && \
    touch uid_gid_setup


go get github.com/AriseBank/apollo-controller
cd $GOPATH/src/github.com/AriseBank/apollo-controller
go get -v -d ./...
make


cat << 'EOF' | sudo tee /etc/init/apollo.conf
description "APOLLO daemon"
author      "John Brooker"

start on filesystem or runlevel [2345]
stop on shutdown

script

    exec /home/vagrant/go/bin/apollo --group vagrant

end script

EOF

sudo service apollo start
