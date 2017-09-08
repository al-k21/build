#!/bin/bash
############################################################################
#
#               ------------------------------------------
#               THIS SCRIPT PROVIDED AS IS WITHOUT SUPPORT
#               ------------------------------------------
#
# Author: Vinicius Silva <vesoares@br.ibm.com>
# Version: 0.5
# Description: Wrapper script for subscription-manager to register RHEL 6
#              and RHEL 7 systems with the internal Red Hat Satellite using
#              FTP3 credentials.
#
# The following environment variables can be used:
#
#   FTP3USER=user@cc.ibm.com        FTP3 Account
#   FTP3PASS=mypasswd               FTP3 Password
#
# You must be root to run this script. The user id and password will be
# prompted for if the environment variables are not set.
#
# example uses might be:
#
#  1.  ./ibm-rhsm.sh
#  2.  FTP3USER=user@cc.ibm.com ./ibm-rhsm.sh
#
# The first example is a good way to test this script. The second example
# shows how to set the FTP3USER environment variable on the command line.
#
# NOTE: Some parts of this script were extracted
#       from the good old ibm-yum.sh script.
#
############################################################################


## default host
if [ -z "$FTP3HOST" ] ; then
    FTP3HOST="ftp3.linux.ibm.com"
fi

## other vars that most likely should not change
API_URL="https://ftp3.linux.ibm.com/rpc/index.php"
KATELLO_CERT_RPM="katello-ca-consumer-rhs.linux.ibm.com"
IBM_RHSM_REG_LOG=ibm-rhsm.log

## these are detected automatically
ARCH=
VERSION=
RELEASE=

## registration successfull
SUCCESS=

## system already registered check
PROCEED=

## Functions

# 0 = green; 1 = red; 2 = yellow
formatted_echo() {
    case $2 in
        0   ) echo -e "\r\t\t\t\t\t\t\t\e[32m$1\e[0m";;
        1   ) echo -e "\r\t\t\t\t\t\t\t\e[31m$1\e[0m";;
        2   ) echo -e "\r\t\t\t\t\t\t\t\e[33m$1\e[0m";;
        *   ) echo $1;;
    esac
}

run_curl() {
    user=$1
    pass=$2

    curl -ks $API_URL  -H "Content-Type: text/xml" -d "<?xml version='1.0' encoding='UTF-8'?><methodCall><methodName>user.create_activation_key</methodName> <params><param><value>$user</value></param> <param><value>$pass</value></param></params> </methodCall>" | grep -oPm1 "(?<=<string>)[^<]+"

    if [ $? != 0 ]; then
        echo
        echo "An error has occurred while trying to create the activation key."
        echo "Aborting..."
        echo
        exit 1
    fi
}

## this is called on exit
clean_up() {
    if [ -z "$SUCCESS" ]; then
        rpm -q --quiet $KATELLO_CERT_RPM
        if [ $? -eq 0 ]; then
            echo "Cleaning up..."
            rpm -e $KATELLO_CERT_RPM
        fi
        exit 1
    fi
    exit 0
}

## clean up proper if something goes bad
trap clean_up EXIT HUP INT QUIT TERM;


## must be root to run this
if [ `whoami` != "root" ] ; then
    echo "You must run this script as root. Goodbye."
    echo ""
    exit 1
fi

## initialize the log file
cat /dev/null > $IBM_RHSM_REG_LOG
echo `date` >> $IBM_RHSM_REG_LOG
echo "Starting the registration process..." >> $IBM_RHSM_REG_LOG

## system is already registered?
REGSTATUS=`subscription-manager status | grep Overall | cut -f2 -d':' | tr -d ' '`
if [ "$REGSTATUS" == "Current" ]; then
    echo "This system is already registered."
    echo -n "Would like to proceed? (y/n): "
    read PROCEED

    if [ "$PROCEED" != "y" -a "$PROCEED" != "Y" ]; then
        echo "Aborting..."
        exit 1
    fi
fi

## get the userid
if [ -z "$FTP3USER" ] ; then
    echo -n "User ID: "
    read FTP3USER

    if [ -z "$FTP3USER" ] ; then
        echo ""
        echo "Missing userid. Either set the environment variable"
        echo "FTP3USER to your user id or enter a user id when prompted."
        echo "Goodbye."
        echo ""
        exit 1
    fi
fi

## get the password
if [ -z "$FTP3PASS" ] ; then
    echo -n "Password for $FTP3USER: "
    stty -echo
    read -r FTP3PASS
    stty echo
    echo ""
    echo ""

    if [ -z "$FTP3PASS" ] ; then
        echo "Missing password. Either set the environment variable"
        echo "FTP3PASS to your user password or enter a password when"
        echo "prompted. Goodbye."
        echo ""
        exit 1
    fi
fi

echo -n "* Performing initial checks... "

## get the version and release, most likely only works on RHEL
VERREL=`rpm -qf --qf "%{NAME}-%{VERSION}\n" /etc/redhat-release`
if [ $? != 0 ] ; then
    formatted_echo "FAIL" 1
    echo "Failed to find system version and release with the"
    echo "command \"rpm -q redhat-release\". Is this system"
    echo "running Red Hat Enterprise Linux?"
    echo ""
    exit 1
fi

## split something like "redhat-release-server-7.1" into "7" and "server"
RELEASE=`echo $VERREL | cut -f4 -d"-" | cut -b1`
VERSION=`echo $VERREL | cut -f3 -d"-"`

## verify support for this release
case $RELEASE in
    7   ) : ;;
    6   ) : ;;
    *   ) RELEASE= ;;
esac

## verify support for this version
case $VERSION in
    server      ) : ;;
    workstation ) : ;;
    *           ) VERSION= ;;
esac

if [ -z "$VERSION" ] || [ -z "$RELEASE" ] ; then
    formatted_echo "FAIL" 1
    echo "Unknown or unsupported system version and release: $VERREL"
    echo "Try reporting this to ftpadmin@linux.ibm.com with the"
    echo "full output of uname -a and the contents of /etc/redhat-release"
    echo ""
    exit 1
fi

## get the system arch
# TODO: Refactor this by declaring and reusing the $ARCH variable
case `uname -m` in
    x86_64      ) ARCH="x86_64"
                  LABEL="$VERSION"
                  ;;
    ppc64le     ) ARCH="ppc64le"
                  LABEL="for-power-le"
                  ;;
    ppc64       ) ARCH="ppc64"
                  LABEL="for-power"
                  ;;
    s390x       ) ARCH="s390x"
                  LABEL="for-system-z"
                  ;;
    *           ) ARCH=;;
esac

## check if we got a good arch
if [ -z "$ARCH" ] ; then
    # TODO: Move the following lines inside the default case (*) statement
    formatted_echo "FAIL" 1
    echo "Unsupported system architecture: `uname -m`"
    echo "If you have any questions, please open a support request at:"
    echo -e "http://ltc.linux.ibm.com/support/ltctools.php.\n"
    exit 1
fi

formatted_echo "OK" 0
echo "Detected a RHEL $RELEASE $VERSION..." >> $IBM_RHSM_REG_LOG

## system is registered to the old RHN Satellite?
REGSTATUS=`rpm -q rhn-org-trusted-ssl-cert-1.0-10`
if [ $? -eq 0 ]; then
    echo "This system is registered to the old RHN Satellite. "
    echo -n "Would like to proceed and remove current associations? (y/n): "
    read PROCEED

    if [ "$PROCEED" != "y" -a "$PROCEED" != "Y" ]; then
        echo "Aborting..."
        exit 1
    fi
    yum remove rhn-org-trusted-ssl-cert-1.0-10 -y &>> $IBM_RHSM_REG_LOG
    sed -i 's/enabled\ =\ 1/enabled\ =\ 0/g' /etc/yum/pluginconf.d/rhnplugin.conf
fi

# Encode the username for use in URLs
FTP3USERENC=`echo $FTP3USER | sed s/@/%40/g`

# Encode user password for use in URLs
FTP3PASSENC=`echo -n $FTP3PASS | od -tx1 -An | tr -d '\n' | sed 's/ /%/g'`

echo -n "* Check the server certificate... "
rpm -qa | grep -s katello-ca-consumer > /dev/null
if [ $? -ne 0 ]; then
    formatted_echo "WARN" 2
    echo "The server certificate is not installed." >> $IBM_RHSM_REG_LOG

    echo -n "* -> Installing server certificate... " | tee -a $IBM_RHSM_REG_LOG
    echo >> $IBM_RHSM_REG_LOG
    rpm -Uvh http://rhs.linux.ibm.com/pub/katello-ca-consumer-latest.noarch.rpm &>> $IBM_RHSM_REG_LOG
    if [ $? -ne 0 ]; then
        formatted_echo "FAIL" 1
        echo "An error has occurred while trying to install the server certificate." >> $IBM_RHSM_REG_LOG
        echo "Aborting..."
        echo
        exit 1
    else
        formatted_echo "OK" 0
    fi
else
    formatted_echo "OK" 0
    echo "Server certificate is already installed." >> $IBM_RHSM_REG_LOG
fi

## Get activation key
# in case an existing key is not found, a new one will be created.
echo -n "* Searching for an activation key... "

ACTIVATION_KEY=`run_curl $FTP3USERENC $FTP3PASSENC`

if [ -z "$ACTIVATION_KEY" ]; then
    formatted_echo "FAIL" 1
    echo
    echo -n "An error has ocurred: "
    echo "No activation key."
    echo "There was a problem while creating your activation key."
    echo "Please, make sure you are connected to the IBM network and using a valid FTP3 account."
    echo "Aborting."
    echo
    exit 1
elif [ "$ACTIVATION_KEY" == "Account not found" -o "$ACTIVATION_KEY" == "Wrong username or password" ]; then
    formatted_echo "FAIL" 1
    echo
    echo "An error has ocurred: $ACTIVATION_KEY"
    echo "Please, make sure you're using the correct FTP3 username and password."
    echo "Aborting."
    echo
    exit 1
elif [ "$ACTIVATION_KEY" == "The account $FTP3USER does not have access to Red Hat content" ]; then
    formatted_echo "FAIL" 1
    echo
    echo "An error has ocurred: $ACTIVATION_KEY"
    echo -n "You may request access on the \"My Account\" page: "
    echo "https://ftp3.linux.ibm.com/myaccount/access.php."
    echo "Aborting."
    echo
    exit 1
fi
formatted_echo "OK" 0
echo "Activation key: $ACTIVATION_KEY" >> $IBM_RHSM_REG_LOG
echo "(You may copy this activation key for future use)" >> $IBM_RHSM_REG_LOG

## system registration
echo -n "* Registering the system... "
REGSTATUS=`subscription-manager register --org Default_Organization --activationkey="$ACTIVATION_KEY"`

if [ `echo $REGSTATUS | grep -c "The system has been registered"` -ne 1 ]; then
    formatted_echo "FAIL" 1
    echo "An error has occurred while trying to register the system."
    echo "You may try to register it later using the following command:"
    echo "subscription-manager register --org Default_Organization --activationkey=\"$ACTIVATION_KEY\""
    echo
    exit 1
else
    echo "System successfully registered!" >> $IBM_RHSM_REG_LOG
    formatted_echo "OK" 0
fi

## Disable all repositories
echo -n "* Disable all repositories... " | tee -a $IBM_RHSM_REG_LOG
echo >> $IBM_RHSM_REG_LOG

subscription-manager repos --disable=* >> $IBM_RHSM_REG_LOG
if [ $? -ne 0 ]; then
    formatted_echo "FAIL" 1
    #echo "An error has occurred while disabling all the repositories." >> $IBM_RHSM_REG_LOG
else
    formatted_echo "OK" 0
fi

## Enable RHEL 7 repositories
echo -n "* Enable RHEL $RELEASE repositories... " | tee -a $IBM_RHSM_REG_LOG
echo >> $IBM_RHSM_REG_LOG

arr=("-supplementary-" "-optional-" "-")
for REPO in "${arr[@]}"; do
    subscription-manager repos --enable=rhel-$RELEASE-${LABEL}${REPO}rpms >> $IBM_RHSM_REG_LOG
    if [ $? -ne 0 ]; then
        ENABLE_REPOS=0
    fi
done

if [ -z $ENABLE_REPOS ]; then
    formatted_echo "OK" 0
else
    formatted_echo "FAIL" 1
fi

SUCCESS=0

echo
echo "Registration completed!" | tee -a $IBM_RHSM_REG_LOG

exit 0
