#!/bin/bash
#
# Copyright (C) 2015 eNovance SAS <licensing@enovance.com>
#
# Author: Frederic Lepied <frederic.lepied@enovance.com>
#
# Licensed under the Apache License, Version 2.0 (the "License"); you may
# not use this file except in compliance with the License. You may obtain
# a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
# WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
# License for the specific language governing permissions and limitations
# under the License.


### Intial definitions

set -ue

ORIG=$(cd $(dirname $0); pwd)
PREFIX=$USER
installserver_name="os-ci-test4"
router_name="router"
routerip=""
installserverip=""
virthost="localhost"
platform="virt_platform.yaml"

### Handler Functions

usage () {
        echo "
usage: $0 [OPTION]
Collect architecture information from the edeploy directory as generated
by config-tools/download.sh and use the virtulizor.py to boostrap a SpS platform.

arguments:
    -h|--help                     Show this help
    -H|--hypervisor=name          Set the hypervisor hostname, default (${virthost})
    -d|--debug                    Set the debug mode for this script, default: disabled
    -w|--wordkir=dir1,dir2,...    Workdir List, default: None
    -v|--virt=virt_platform.yml   Set the path to the infra's yaml, default: virt_platform.yaml
    -e|--extra='--replace'        Add extra parameters to virtulizor.py
    -p|--prefix                   Change the platform's prefix, default: unix user
    -s|--socks                    Create a socks server to test your platform
    -t|--tempest                  Launch the sanity job at the end of a deployement

For example:
./virtualize.sh -H localhost -d -v virt_platform.yml -e '--replace' -w I.1.2.1,I.1.3.0,I.1.3.1
will deploy environment I.1.2.1 and upgrade to I.1.3.0 and then I.1.3.1.

and
./virtualize.sh -H localhost -v virt_platform.yml -e '--replace' -w ../config-tools/ -s -t
will deploy the env in your directory config-tools/, create a tunnel socks and launch tempest"
}

debug() {
    set -x
}

upload_logs() {
    [ -f ~/openrc ] || return

    source ~/openrc
    BUILD_PLATFORM=${BUILD_PLATFORM:-"unknown_platform"}
    CONTAINER=${CONTAINER:-"unknown_platform"}
    for path in /var/lib/edeploy/logs /var/log  /var/lib/jenkins/jobs/puppet/workspace; do
        mkdir -p ${LOG_DIR}/$(dirname ${path})
        scp ${SSHOPTS} -r root@${installserverip}:${path} ${LOG_DIR}/${path}
    done
    find ${LOG_DIR} -type f -exec chmod 644 '{}' \;
    find ${LOG_DIR} -type d -exec chmod 755 '{}' \;
    for file in $(find ${LOG_DIR} -type f -printf "%P\n"); do
        swift upload --object-name ${BUILD_PLATFORM}/${PREFIX}/$(date +%Y%m%d-%H%M)/${file} ${CONTAINER} ${LOG_DIR}/${file}
    done
    swift post -r '.r:*' ${CONTAINER}
    swift post -m 'web-listings: true' ${CONTAINER}
}

get_ip() {
    local mac=$1
    local ip=$(ssh ${SSHOPTS} root@${virthost} "awk '/ ${mac} / {print \$3}' /var/lib/libvirt/dnsmasq/nat.leases"|head -n 1)
    echo ${ip}
}

get_mac() {
    local name=$1
    local mac=$(ssh ${SSHOPTS} root@${virthost} cat /etc/libvirt/qemu/${PREFIX}_${name}.xml|xmllint --xpath 'string(/domain/devices/interface[last()]/mac/@address)' -)
    echo ${mac}
}

drop_host() {
    local host=$1

    ssh $SSHOPTS root@$virthost virsh destroy ${host}
    for snapshot in $(ssh $SSHOPTS root@$virthost virsh snapshot-list --name ${host}); do
        ssh $SSHOPTS root@$virthost virsh snapshot-delete ${host} ${snapshot}
    done
    ssh $SSHOPTS root@$virthost virsh undefine --remove-all-storage ${host}
}

deploy() {
    local ctdir=$1
    shift
    local do_upgrade=$1
    shift
    local extra_args=$*

    virtualizor_extra_args="${extra_args} --pub-key-file ${HOME}/.ssh/id_rsa.pub"

    if [ -n "$SSH_AUTH_SOCK" ]; then
        ssh-add -L > pubfile
        virtualizor_extra_args+=" --pub-key-file pubfile"
    fi

    if [ ${do_upgrade} = 1 ]; then
        # On upgrade, we redeploy the install-server and the router.
        drop_host ${PREFIX}_${installserver_name}
        drop_host ${PREFIX}_router
        jenkins_job_name="upgrade"
    else
        jenkins_job_name="puppet"
    fi

    $ORIG/virtualizor.py "${platform}" ${virthost} --prefix ${PREFIX} --public_network nat --pub-key-file ${pubfile} ${virtualizor_extra_args}
    local mac=$(get_mac ${installserver_name})
    installserverip=$(get_ip ${mac})
    local mac=$(get_mac ${router_name})
    routerip=$(get_ip ${mac})

    local retry=0
    for user_home in /root/root /var/lib/jenkins; do
        chmod -f 755 ${ctdir}/top${user_home} ${ctdir}/top${user_home}/.ssh || true
        # We do not copy the /root/.ssh/id_rsa to preserve our “unsecure” private SSH key
        # and continue to be able to connect to the different nodes
        rm -f ${ctdir}/top/${user_home}/.ssh/id_rsa
    done
    while ! rsync -e "ssh $SSHOPTS" --quiet -av --no-owner --no-group ${ctdir}/top/ root@$installserverip:/; do
        if [ $((retry++)) -gt 300 ]; then
            echo "reached max retries"
            exit 1
        else
            echo "install-server (${installserverip}) not ready yet. waiting..."
        fi
        sleep 10
        echo -n .
    done

    scp ${SSHOPTS} ${ctdir}/extract-archive.sh ${ctdir}/functions root@${installserverip}:/tmp

    ssh ${SSHOPTS} root@$installserverip "
    [ -d /var/lib/edeploy ] && echo -e 'RSERV=localhost\nRSERV_PORT=873' >> /var/lib/edeploy/conf"

    ssh ${SSHOPTS} root@${installserverip} /tmp/extract-archive.sh
    ssh ${SSHOPTS} root@${installserverip} rm /tmp/extract-archive.sh /tmp/functions
    ssh ${SSHOPTS} root@${installserverip} "ssh-keygen -y -f ~jenkins/.ssh/id_rsa >> ~jenkins/.ssh/authorized_keys"
    ssh ${SSHOPTS} root@${installserverip} service dnsmasq restart
    ssh ${SSHOPTS} root@${installserverip} service httpd restart
    ssh ${SSHOPTS} root@${installserverip} service rsyncd restart

    # TODO(Gonéri): We use the hypervisor as a mirror/proxy
    ssh ${SSHOPTS} root@${installserverip} "echo 10.143.114.133 os-ci-edeploy.ring.enovance.com >> /etc/hosts"


    ssh ${SSHOPTS} root@${installserverip} "
    . /etc/config-tools/config
    retry=0
    while true; do
        if [  \${retry} -gt $TIMEOUT_ITERATION ]; then
            echo 'Timeout'
            exit 1
        fi
        ((retry++))
        for node in \${HOSTS}; do
            sleep 1
            echo -n .
            ssh $SSHOPTS jenkins@\${node} uname > /dev/null 2>&1|| continue 2
            # NOTE(Gonéri): on I.1.2.1, the ci.pem file is deployed through
            # cloud-init. Since we can use our own cloud-init files, this file
            # is not installed correctly.
            if [ -f /etc/ssl/certs/ci.pem ]; then
                scp ${SSHOPTS} /etc/ssl/certs/ci.pem root@\${node}:/etc/ssl/certs/ci.pem || exit 1
            fi
            # TODO(Gonéri): Something we need for the upgrade, we will need a
            # better way to identify the install-server.
            ssh ${SSHOPTS} root@\${node} \"echo 'RSERV=${installserver_name}' >> /var/lib/edeploy/conf\"
            ssh ${SSHOPTS} root@\${node} \"echo 'RSERV_PORT=873' >> /var/lib/edeploy/conf\"
            ssh ${SSHOPTS} root@\${node} \"echo 'Defaults:jenkins !requiretty' > /etc/sudoers.d/999-jenkins-cloud-init-requiretty\"
            ssh ${SSHOPTS} root@\${node} \"echo 'jenkins ALL=(ALL) NOPASSWD:ALL' >> /etc/sudoers.d/999-jenkins-cloud-init-requiretty\"
        done
        break
    done
    "

    while curl --silent http://${installserverip}:8282/job/${jenkins_job_name}/build|\
            grep "Your browser will reload automatically when Jenkins is read"; do
        sleep 1;
    done


    jenkins_log_file="/var/lib/jenkins/jobs/${jenkins_job_name}/builds/1/log"
    (
        ssh ${SSHOPTS} root@${installserverip} "
    while true; do
        [ -f ${jenkins_log_file} ] && tail -n 1000 -f ${jenkins_log_file}
        sleep 1
    done"
    ) &
    tail_job=$!

    # Wait for the first job to finish
    ssh ${SSHOPTS} root@${installserverip} "
        while true; do
            test -f /var/lib/jenkins/jobs/${jenkins_job_name}/builds/1/build.xml && break;
            sleep 1;
        done"

    kill ${tail_job}
    if [ $do_upgrade -eq 0 ]; then
        if ! [ -z ${socks+x} ]; then
            create_socks ${routerip}
        fi
    fi

    if [ ${tempest} == "True" ]; then
        #Launch Sanity and show the logs
        curl --silent http://${installserverip}:8282/job/sanity/build
        sanity_log_file="/var/lib/jenkins/jobs/sanity/builds/1/log"
        (
            ssh ${SSHOPTS} root@${installserverip} "
                while true; do
                    [ -f ${sanity_log_file} ] && tail -n 1000 -f ${sanity_log_file}
                    sleep 1
                done"
        ) &

        #Wait until build finish
        ssh ${SSHOPTS} root@${installserverip} "
            while true; do
                test -f /var/lib/jenkins/jobs/sanity/builds/1/build.xml && break;
                sleep 1;
            done"
    fi
}

create_socks() {
    local port=1080
    routerip=$1
    portlist=$(ssh ${SSHOPTS} root@${virthost} netstat -lntp | awk '{print $4}' | awk -F':' '{print $NF}' | grep 108.)
    while [ "${portlist}x" != "x" ] ; do
        if [ $(echo ${portlist} | grep ${port} | wc -l) -eq 1 ]; then
            ((port++))
        elif [ ${port} -eq 1090 ]; then
            echo "Not enough port on this hypervisor, 10 platform launch ..."
            exit 1
        else
            break
        fi
    done
    ssh ${SSHOPTS} -f -N -D 0.0.0.0:${port} ${routerip}
    echo "Port ${port} for the server socks"
}

### Arguments parsing

ARGS=$(getopt -o w:v:ste:p:dH:h -l "wordkir:,virt:,socks,tempest,extra:,platform,debug,hypervisor:,help" -- "$@");
#Bad arguments
if [ $? -ne 0 ]; then
    usage
    exit 1
fi

eval set -- "$ARGS";
while true; do
    case "$1" in
        -d|--debug)
            shift
            debug
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        -H|--hypervisor)
            shift;
            if [ -n "$1" ]; then
                virthost=$1
                shift;
            fi
            ;;
        -p|--prefix)
            shift;
            if [ -n "$1" ]; then
                PREFIX=$1
                shift;
            fi
            ;;
        -e|--extra)
            shift;
            if [ -n "$1" ]; then
                extra_args=$1
                shift;
            fi
            ;;
        -w|--workdir)
            shift;
            if [ -n "$1" ]; then
                workdirs=$1
                shift;
            fi
            ;;
        -v|--virt)
            shift;
            if [ -n "$1" ]; then
                platform=$1
                shift;
            fi
            ;;
        -s|--socks)
            socks="True"
            shift;
            ;;
        -t|--tempest)
            tempest="True"
            shift;
            ;;
        --)
            shift
            break
            ;;
        *)
            echo "$1 : Wrong parameters"
            usage
            exit 1
            ;;
    esac
done

[ -f ~/virtualizerc ] && source ~/virtualizerc

### Handler stuff

# Default values if not set by user env
TIMEOUT_ITERATION=${TIMEOUT_ITERATION:-"150"}
LOG_DIR=${LOG_DIR:-"$(pwd)/logs"}

SSHOPTS="-oBatchMode=yes -oCheckHostIP=no -oHashKnownHosts=no  -oStrictHostKeyChecking=no -oPreferredAuthentications=publickey  -oChallengeResponseAuthentication=no -oKbdInteractiveDevices=no -oUserKnownHostsFile=/dev/null -oControlPath=~/.ssh/control-%r@%h:%p -oControlMaster=auto -oControlPersist=30"

if [ -n "${SSH_AUTH_SOCK}" ]; then
    ssh-add -L > pubfile
    pubfile=pubfile
else
    pubfile=~/.ssh/id_rsa.pub
fi

do_upgrade=0
IFS=","
for workdir in ${workdirs}; do
    unset IFS
    if [ -z ${extra_args+x} ]; then
        deploy ${workdir} ${do_upgrade}
    else
        deploy ${workdir} ${do_upgrade} ${extra_args}
    fi
    do_upgrade=1
done
unset IFS

# Dump elasticsearch logs into ${LOG_DIR},
# upload_logs will update the dump in swift.
$ORIG/dumpelastic.py --url http://${installserverip}:9200 --output-dir ${LOG_DIR}

upload_logs

#ssh $SSHOPTS -A root@$installserverip configure.sh

# virtualize.sh ends here
