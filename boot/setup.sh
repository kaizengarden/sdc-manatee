#!/bin/bash
# -*- mode: shell-script; fill-column: 80; -*-
#
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
#

#
# Copyright (c) 2014, Joyent, Inc.
#

export PS4='[\D{%FT%TZ}] ${BASH_SOURCE}:${LINENO}: ${FUNCNAME[0]:+${FUNCNAME[0]}(): }'
set -o xtrace

SOURCE="${BASH_SOURCE[0]}"
if [[ -h $SOURCE ]]; then
    SOURCE="$(readlink "$SOURCE")"
fi
DIR="$( cd -P "$( dirname "$SOURCE" )" && pwd )"
PROFILE=/root/.bashrc
SVC_ROOT=/opt/smartdc/manatee
role=manatee
REGISTRAR_CFG=/opt/smartdc/registrar/etc/config.json

export PATH=$SVC_ROOT/build/node/bin:/opt/local/bin:/usr/sbin/:/usr/bin:$PATH

# Install zookeeper package, need to touch this file to disable the license prompt
touch /opt/local/.dli_license_accepted


function sdc_manatee_setup {
    # vars used by manatee-* tools
    ZONE_UUID=$(json -f /var/tmp/metadata.json ZONE_UUID)
    DATASET=zones/$ZONE_UUID/data/manatee
    PARENT_DATASET=zones/$ZONE_UUID/data
    DATASET_MOUNT_DIR=/manatee/pg
    PG_DIR=/manatee/pg/data
    PG_LOG_DIR=/var/pg
    ZONE_IP=$(json -f /var/tmp/metadata.json ADMIN_IP)
    SHARD=$(json -f /var/tmp/metadata.json SERVICE_NAME)
    BINDER_ADMIN_IPS=$(json -f /var/tmp/metadata.json binder_admin_ips)

    # Cookie to identify this as a SmartDC zone and its role
    mkdir -p /var/smartdc/$role
    mkdir -p /opt/smartdc/$role/ssl

    #echo "Installing local node.js"
    mkdir -p /opt/smartdc/$role/etc
    /usr/bin/chown -R root:root /opt/smartdc

    # Add build/node/bin and node_modules/.bin to PATH
    echo "" >>/root/.profile
    echo "export PATH=\$PATH:/opt/smartdc/$role/build/node/bin:/opt/smartdc/$role/node_modules/.bin" >>/root/.profile

    #cron
    mkdir -p /var/log/manatee/
    local crontab=/tmp/.sdc_manatee_cron
    crontab -l > $crontab

    echo "0 0 * * * /opt/smartdc/manatee/pg_dump/pg_dump.sh >> /var/log/manatee/pgdump.log 2>&1" >> $crontab
    [[ $? -eq 0 ]] || fatal "Unable to write to $crontab"
    crontab $crontab
    [[ $? -eq 0 ]] || fatal "Unable import crons"

    # rotate pgdump logs
    sdc_log_rotation_add pgdump /var/log/manatee/pgdump.log 1g

    sdc_log_rotation_setup_end

    common_manatee_setup

    common_enable_services
}

function common_enable_services {
    # import services
    echo "Starting snapshotter"
    svccfg import /opt/smartdc/manatee/smf/manifests/snapshotter.xml
    svcadm enable manatee-snapshotter

    echo "Starting backupserver"
    svccfg import /opt/smartdc/manatee/smf/manifests/backupserver.xml
    svcadm enable manatee-backupserver

    svccfg import /opt/smartdc/manatee/smf/manifests/sitter.xml
    # For SDC we'll let configure decide if it wants to enable sitter or not.
}

function common_manatee_setup {
    # create manatee dataset
    echo "creating manatee dataset"
    zfs create -o canmount=noauto $DATASET

    # create postgres user
    echo "creating postgres user"
    useradd postgres

    # grant postgres user chmod chown privileges with sudo
    echo "postgres    ALL=(ALL) NOPASSWD: /usr/bin/chown, /usr/bin/chmod, /opt/local/bin/chown, /opt/local/bin/chmod" >> /opt/local/etc/sudoers

    # give postgres user zfs permmissions.
    echo "grant postgres user zfs perms"
    zfs allow -ld postgres create,destroy,diff,hold,release,rename,setuid,rollback,share,snapshot,mount,promote,send,receive,clone,mountpoint,canmount $PARENT_DATASET

    # change dataset perms such that manatee can access the dataset and mount/unmount
    mkdir -p $DATASET_MOUNT_DIR
    chown -R postgres $DATASET_MOUNT_DIR
    chmod 700 -R $DATASET_MOUNT_DIR

    # set mountpoint
    zfs set mountpoint=$DATASET_MOUNT_DIR $DATASET

    # mount the dataset
    zfs mount $DATASET

    # make the pg data dir
    echo "creating $PG_DIR"
    mkdir -p $PG_DIR
    chown postgres $PG_DIR
    chmod 700 $PG_DIR

    # make .zfs dir visible for snapshots
    echo "make snapshot dir visible"
    zfs set snapdir=visible $DATASET

    # add pg log dir
    mkdir -p $PG_LOG_DIR
    chown -R postgres $PG_LOG_DIR
    chmod 700 $PG_LOG_DIR
}

function add_manatee_profile_functions {
    ZK_IPS=${BINDER_ADMIN_IPS}

    #.bashrc
    echo "export PATH=\$PATH:/opt/smartdc/manatee/bin/:/opt/smartdc/manatee/pg_dump/:/opt/smartdc/manatee/node_modules/manatee/bin" >>/root/.bashrc
    echo "export MANPATH=\$MANPATH:/opt/smartdc/manatee/node_modules/manatee/man" >> /root/.bashrc
    # get correct ZK_IPS
    echo "source /opt/smartdc/etc/zk_ips.sh" >> $PROFILE

    # get correct ZK_IPS
    echo "source /opt/smartdc/etc/zk_ips.sh" >> $PROFILE
    echo "export ZK_IPS=\"$ZK_IPS\"" >> $PROFILE

    # export shard
    local shard=$(cat /opt/smartdc/manatee/etc/sitter.json | json shardPath | \
        cut -d '/' -f3)
    echo "export SHARD=$shard" >> $PROFILE

    # export sitter config
    echo "export MANATEE_SITTER_CONFIG=/opt/smartdc/manatee/etc/sitter.json" \
        >> $PROFILE

    #functions
    echo "zbunyan() { bunyan -c \"this.component !== 'ZKPlus'\"; }" >> $PROFILE
    echo "mbunyan() { bunyan -c \"this.component !== 'ZKPlus'\"  -c 'level >= 30'; }" >> $PROFILE
    echo "msitter(){ tail -f \`svcs -L manatee-sitter\` | mbunyan; }" >> $PROFILE
    echo "mbackupserver(){ tail -f \`svcs -L manatee-backupserver\` | mbunyan; }" >> $PROFILE
    echo "msnapshotter(){ tail -f \`svcs -L manatee-snapshotter\` | mbunyan; }" >> $PROFILE
    echo "manatee-stat(){ manatee-adm status; }" >> $PROFILE
}


# Local manifests
CONFIG_AGENT_LOCAL_MANIFESTS_DIRS=/opt/smartdc/$role

# Include common utility functions (then run the boilerplate)
source /opt/smartdc/boot/lib/util.sh
sdc_common_setup

# add log rotation
sdc_log_rotation_add manatee-sitter /var/svc/log/*manatee-sitter*.log 1g
sdc_log_rotation_add manatee-sitter /var/svc/log/*manatee-snapshotter*.log 1g
sdc_log_rotation_add manatee-sitter /var/svc/log/*manatee-backupserver*.log 1g
sdc_log_rotation_add manatee-postgres /var/pg/postgresql.log 1g
sdc_log_rotation_setup_end

# Do the SDC-specific manatee stuff.
sdc_manatee_setup
add_manatee_profile_functions

# All done, run boilerplate end-of-setup
sdc_setup_complete

exit 0
