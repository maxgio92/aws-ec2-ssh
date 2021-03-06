#!/bin/bash -e

show_help() {
cat << EOF
Usage: ${0##*/} [-hv] [-a ARN] [-i GROUP,GROUP,...] [-l GROUP,GROUP,...] [-s GROUP] [-p PROGRAM] [-u "ARGUMENTS"]
Install import_users.sh and authorized_key_commands.

    -h                 display this help and exit
    -v                 verbose mode.

    -a arn             Assume a role before contacting AWS IAM to get users and keys.
                       This can be used if you define your users in one AWS account, while the EC2
                       instance you use this script runs in another.
    -i group,group     Which IAM groups have access to this instance
                       Comma seperated list of IAM groups. Leave empty for all available IAM users
    -l group,group     Give the users these local UNIX groups
                       Comma seperated list
    -s group,group     Specify IAM group(s) for users who should be given sudo privileges, or leave
                       empty to not change sudo access, or give it the value '##ALL##' to have all
                       users be given sudo rights.
                       Comma seperated list
    -p program         Specify your useradd program to use.
                       Defaults to '/usr/sbin/useradd'
    -u "useradd args"  Specify arguments to use with useradd.
                       Defaults to '--create-home --shell /bin/bash'


EOF
}

get_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS=$NAME
    elif type lsb_release >/dev/null 2>&1; then
        OS=$(lsb_release -si)
    elif [ -f /etc/lsb-release ]; then
        . /etc/lsb-release
        OS=$DISTRIB_ID
    elif [ -f /etc/debian_version ]; then
        OS='Debian'
    elif [ -f /etc/redhat-release ]; then
        OS='Red Hat'
    else
        OS=$(uname -s)
    fi
}

SSHD_CONFIG_FILE="/etc/ssh/sshd_config"
AUTHORIZED_KEYS_COMMAND_FILE="/opt/authorized_keys_command.sh"
IMPORT_USERS_SCRIPT_FILE="/opt/import_users.sh"
MAIN_CONFIG_FILE="/etc/aws-ec2-ssh.conf"

IAM_GROUPS=""
SUDO_GROUPS=""
LOCAL_GROUPS=""
ASSUME_ROLE=""
USERADD_PROGRAM=""
USERADD_ARGS=""

DEBIAN_BASED_OS=('Debian GNU/Linux' 'Ubuntu')
RHEL_BASED_OS=('Amazon Linux AMI' 'CentOS Linux' 'Red Hat Enterprise Linux Server')

while getopts :hva:i:l:s: opt
do
    case $opt in
        h)
            show_help
            exit 0
            ;;
        i)
            IAM_GROUPS="$OPTARG"
            ;;
        s)
            SUDO_GROUPS="$OPTARG"
            ;;
        l)
            LOCAL_GROUPS="$OPTARG"
            ;;
        v)
            set -x
            ;;
        a)
            ASSUME_ROLE="$OPTARG"
            ;;
        p)
            USERADD_PROGRAM="$OPTARG"
            ;;
        u)
            USERADD_ARGS="$OPTARG"
            ;;
        \?)
            echo "Invalid option: -$OPTARG" >&2
            show_help
            exit 1
            ;;
        :)
            echo "Option -$OPTARG requires an argument." >&2
            show_help
            exit 1
    esac
done

get_os

if [[ " ${DEBIAN_BASED_OS[*]} " == *" ${OS} "* ]]; then
    SSHD_SERVICE_NAME=ssh
elif [[ " ${RHEL_BASED_OS[*]} " == *" ${OS} "* ]]; then
    SSHD_SERVICE_NAME=sshd
else
    SSHD_SERVICE_NAME=sshd
fi

tmpdir=$(mktemp -d)

cd "$tmpdir"

git clone -b ubuntu https://github.com/widdix/aws-ec2-ssh.git

cd "$tmpdir/aws-ec2-ssh"

cp authorized_keys_command.sh $AUTHORIZED_KEYS_COMMAND_FILE
cp import_users.sh $IMPORT_USERS_SCRIPT_FILE

if [ "${IAM_GROUPS}" != "" ]
then
    echo "IAM_AUTHORIZED_GROUPS=\"${IAM_GROUPS}\"" >> $MAIN_CONFIG_FILE
fi

if [ "${SUDO_GROUPS}" != "" ]
then
    echo "SUDOERS_GROUPS=\"${SUDO_GROUPS}\"" >> $MAIN_CONFIG_FILE
fi

if [ "${LOCAL_GROUPS}" != "" ]
then
    echo "LOCAL_GROUPS=\"${LOCAL_GROUPS}\"" >> $MAIN_CONFIG_FILE
fi

if [ "${ASSUME_ROLE}" != "" ]
then
    echo "ASSUMEROLE=\"${ASSUME_ROLE}\"" >> $MAIN_CONFIG_FILE
fi

if [ "${USERADD_PROGRAM}" != "" ]
then
    echo "USERADD_PROGRAM=\"${USERADD_PROGRAM}\"" >> $MAIN_CONFIG_FILE
fi

if [ "${USERADD_ARGS}" != "" ]
then
    echo "USERADD_ARGS=\"${USERADD_ARGS}\"" >> $MAIN_CONFIG_FILE
fi

if grep -q 'AuthorizedKeysCommand' $SSHD_CONFIG_FILE; then
    sed -i "s:#AuthorizedKeysCommand none:AuthorizedKeysCommand ${AUTHORIZED_KEYS_COMMAND_FILE}:g" $SSHD_CONFIG_FILE
else
    sed -i "/AuthorizedKeysFile/a AuthorizedKeysCommand ${AUTHORIZED_KEYS_COMMAND_FILE}" $SSHD_CONFIG_FILE
fi

if grep -q '#AuthorizedKeysCommandUser' $SSHD_CONFIG_FILE; then
    sed -i "s:#AuthorizedKeysCommandUser nobody:AuthorizedKeysCommandUser nobody:g" $SSHD_CONFIG_FILE
elif ! grep -q 'AuthorizedKeysCommandUser' $SSHD_CONFIG_FILE; then
    sed -i '/AuthorizedKeysCommand/a AuthorizedKeysCommandUser nobody' $SSHD_CONFIG_FILE
fi

cat > /etc/cron.d/import_users << EOF
SHELL=/bin/bash
PATH=/usr/local/bin:/bin:/usr/bin:/usr/local/sbin:/usr/sbin:/sbin:/opt/aws/bin
MAILTO=root
HOME=/
*/10 * * * * root $IMPORT_USERS_SCRIPT_FILE
EOF
chmod 0644 /etc/cron.d/import_users

$IMPORT_USERS_SCRIPT_FILE

service $SSHD_SERVICE_NAME restart
