#!/bin/sh
# WBEMextras checkinstall.sh
# This script is run before "installation" of the package is started
os=$(uname -r)
case $os in
        B.10.2*|B.11.0*)
                echo "[$os] OS is not supported for HPSIM/WEBES/WBEM related stuff."
                exit 1
        ;;
esac


### Remove old versions of WBEMextras if found before installing new version (is net yet registered)
opts=""
ver=$(/usr/sbin/swlist  -l product  -a revision WBEMextras 2>/dev/null | grep -v -E '(\#|^$)' | awk '{print $2}')
arch=$(/usr/sbin/swlist  -l product  -a architecture WBEMextras 2>/dev/null | grep -v -E '(\#|^$)' | awk '{print $2}')
[[ ! -z "${arch}" ]] && opts=",a=${arch}"	# prior version A.01.00.03 architecture was not used
[[ ! -z "${ver}" ]]  && opts="${opts},r=${ver}"

echo "       * Found WBEMextras${opts} on your system"
#echo "       * Found WBEMextras${opts} on your system (swremove it first)"
#/usr/sbin/swremove -x enforce_dependencies=false -x mount_all_filesystems=false WBEMextras${opts}
#sleep 5
