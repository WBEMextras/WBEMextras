#!/usr/bin/ksh
# Author: Gratien D'haese
# Copyright: GPLv3
#
# $Revision:  $
# $Date:  $
# $Header: $
# $Id:  $
# $Locker:  $
# History: Check the bottom of the file for revision history
# ----------------------------------------------------------------------------

###############################################################################
###############################################################################
##									     ##
##	Check HP-UX 11i Remote Support Pack (RSP) Readiness Script	     ##
##	required to install and configure HP-UX 11i systems for		     ##
##	HP Insight Remote Support Standard (IRSS), or			     ##
##	HP Insight Remote Support Advanced (IRSA)			     ##
##	For more information about the product and its components go to      ##
##	http://h18006.www1.hp.com/products/servers/management/\		     ##
##	insight-remote-support/overview.html				     ##
##									     ##
##	Author: Gratien D'haese 					     ##
##									     ##
###############################################################################
###############################################################################
# Goal is to install all HP-SIM/IRSA components on a standarized way on HP-UX
# 11i systems and preferrably as much as possible on an automated way
# This script will check the pre-requisites, install all required software
# pieces, does the needed configuration and send/save a detailed installed
# report. The script knows two modes (preview and installation).
# To run in installation mode use the "-i" option (default is preview mode).

##############
# Parameters #
##############

PS4='$LINENO:=> ' # This prompt will be used when script tracing is turned on

alias export="typeset -x"
alias readonly="typeset -r"
alias int="typeset -i"
alias lower="typeset -l"
alias upper="typeset -u"

export PRGNAME=${0##*/}
export PRGDIR=${0%/*}
export PATH=$PATH:/usr/bin:/usr/sbin:/sbin

[[ $PRGDIR = /* ]] || PRGDIR=$(pwd)	# Acquire absolute path

SWLIST=/usr/sbin/swlist
SWINSTALL=/usr/sbin/swinstall
SWCONFIG=/usr/sbin/swconfig
SWREMOVE=/usr/sbin/swremove
TMPFILE=/tmp/tmpfile4rsp
HOSTNAME=$(uname -n)
ISCRIPT=/tmp/RSP_readiness_${HOSTNAME}.install
CSCRIPT=/tmp/RSP_readiness_${HOSTNAME}.config
EXITCODE=0

typeset OSver=$(uname -r)				# e.g. B.11.11
typeset os=${OSver#B.}					# e.g. 11.11
typeset arch=$(uname -m)				# e.g. 9000/800 or ia64
typeset swarg="-vp"					# by default preview mode with SWINSTALL
int install=1


#############
# Functions #
#############
function _msg {
cat <<eof
NAME
  $PRGNAME - Install and configure IRSS/IRSA software on HP-UX 11i systems

SYNOPSIS
  $PRGNAME [ options ]

DESCRIPTION
  This script will check the pre-requisites, install all required software
  pieces, does the needed configuration and send/save a detailed installed
  report. The script knows two modes (preview and installation).

OPTIONS
  -h
	Print this man page.

  -i
	Run $PRGNAME in "installation" mode. Be careful, this will install software!
	Default is preview mode and is harmless as nothing will be installed nor configured.

  -u <WbemUser>
	Non-priviledge account to use with IRSS/IRSA WBEM protocol (default wbem).

  -g <HpsmhAdminGroup>
	The HP System Management Homepage Admin Group (default hpsmh).

  -m <email1,email2...>
	When this option is used, an  email notification is sent when an error
	occurs.  Use this option with a valid SMTP email address.

  -d [IP address or FQDN of Software Depot server]:<Absolute path to base depot>
	Example: -d 10.0.0.1:/var/opt/ignite/depots/GLOBAL/rsp/pre-req
	The actual software depots are then located under:
	  B.11.11 : /var/opt/ignite/depots/GLOBAL/rsp/pre-req/11.11
	  B.11.23 : /var/opt/ignite/depots/GLOBAL/rsp/pre-req/11.23
	  B.11.31 : /var/opt/ignite/depots/GLOBAL/rsp/pre-req/11.31
	However, -d /cdrom/irsa_1131_apr_2012.depot is also valid where same rules apply as above.

  -p
	Prompt for a password for the WBEM user (non-priviledge user).
	Default password is "hpinvent" (without the double quotes).

  -c <path/configuration file>
	Will store a configuration file as specified which can be used when we
	run this script again. However, other scripts will benefit from this too:
	- HPSIM-HealthCheck.sh 
	- HPSIM-Upgrade-RSP.sh
	- restart_cim_sfm.sh
	Default location/name is [ /usr/local/etc/HPSIM_irsa.conf ]

  -s <HPSIM Server>
	The HP SIM Server address (FQDN or IP address) where $(hostname) will be defined.

  -v
	Prints the version of $PRGNAME.

EXAMPLES
    $PRGNAME -d 10.4.9.76:/var/opt/ignite/depots/GLOBAL/rsp/pre-req
	Run $PRGNAME in preview mode only and will give a status update.
    $PRGNAME -d /test/irsa_1131_apr_2012.depot
	Run $PRGNAME in preview mode only and use a file depot as source depot
    $PRGNAME -i
	Run $PRGNAME in installation mode and use default values for
	IP address of Ignite server (or SD server) and software depot path

IMPLEMENTATION
  version	Id: $PRGNAME $
  Revision	$(_revision)
  Author	Gratien D'haese
  Release Date	26-Jul-2012
eof
}

function _shortMsg {
	cat<<-eof
Usage: $PRGNAME [-vhpi] [-u <WbemUser>] [-g <HpsmhAdminGroup>] [-d IP:path] [-m <email1,email2>] [-c <conf file>] [-s SimServer]
eof
}

function _whoami {
	[ "`whoami`" != "root" ] && _error "You must be root to run this script $PRGNAME on $HOSTNAME"
}

function _error {
	printf " *** ERROR: $* \n"
	echo 99 > /tmp/EXITCODE.rsp
	echo "[Error]: $*" > /tmp/EXITCODE.txt
	exit 1
}

function _note {
        printf " ** $* \n"
}

function _mail {
        [ -s "$instlog" ] || instlog=/dev/null
	if [[ -n $mailusr ]]; then
        	mailx -s "$*" $mailusr < $instlog
	fi
}

function _define_installation_path {
	# installation_path variable contains an IP address and/or path to baseDepo
	echo ${installation_path} | grep -q ":"
	if [[ $? -eq 0 ]]; then
		# IUXSERVER:PATH syntax
		IUXSERVER=$(echo ${installation_path} | cut -d: -f1)
		baseDepo=$(echo ${installation_path} | cut -d: -f2)

	else
		# PATH syntax
		IUXSERVER=localhost
		baseDepo=${installation_path}
	fi
}

function _define_SourceDepot {
	# the source depot can be a directory or a file depot (tar format)
	$SWLIST -l depot  -s ${IUXSERVER} | grep -q "${baseDepo}/$os" 2>/dev/null
	CODE=$?
	if [ $CODE -eq 0 ]; then
		sourceDepo=${IUXSERVER}:${baseDepo}/$os
	else
		sourceDepo=${baseDepo}
		if [[ ! -f ${sourceDepo} ]]; then
			_note "Source depot $sourceDepo is not a tar archive on $(hostname)!"
		fi
	fi
}

function _swinstall {
	# arg1 is the software we want to install
	# arg2 (optional) are extra options required above these mentioned below
	echo $SWINSTALL $swarg -x enforce_dependencies=false -x mount_all_filesystems=false "$2" -s ${sourceDepo} $1
}

function _swremove {
	echo $SWREMOVE $swarg -x enforce_dependencies=false -x mount_all_filesystems=false $1
}

function _swconfig {
	echo $SWCONFIG $swarg -x autoselect_dependencies=false -x reconfigure=true -x mount_all_filesystems=false $1
}

function _netRegion {
	# In a GLOBAL environment it might be possible to have more then 1 software depot server
	# which is usually also the Ignite server
	# Some systems have more than 1 default gateway.

	octet="$(netstat -rn | awk '/default/ && /UG/ { sub (/^[0-9]+\./, "", $2); sub (/\.[0-9]+\.[0-9]+$/,"",$2);
			print $2;
			exit }')"

	IUXSERVER=10.36.96.94 		# default value (NA)
	if [ ${octet} -lt   1 ]; then
		IUXSERVER=10.0.11.237   # dfdev
	elif [ ${octet} -lt  96 ]; then
		IUXSERVER=10.36.96.94   # NA
	elif [ ${octet} -lt 128 ]; then
		IUXSERVER=10.36.96.94   # LA
	elif [ ${octet} -lt 192 ]; then
		IUXSERVER=10.129.52.119 # EMEA
	elif [ ${octet} -lt 224 ]; then
		IUXSERVER=10.129.52.119 # ASPAC
	fi
}


# this function sets the exit to non zero if $1 non numeric
function is_digit {
	expr "$1" + 1 > /dev/null 2>&1
}

function _check_openssl {
	case ${OSver} in
		"B.11.11")
			grep -q -E 'A.02.00-0.9.7c' $TMPFILE
			if [ $? -eq 0 ]; then
				_note "OpenSSL,r=A.02.00-0.9.7c must be removed"
				ActionTest[$1]="echo ${ActionTest[$1]}"
				_upgrade_openssl_string $1 "$(_swremove OpenSSL,r=A.02.00-0.9.7c)"
			fi
			$SWLIST [Oo]pen[Ss][Ss][Ll],r\>=A.00.09.07i.012 >/dev/null 2>&1
			CODE=$?
			if [ $CODE -eq 0 ]; then
				_note "OpenSSL version is OK"
				ActionTest[$1]="echo ${ActionTest[$1]} $2 - OK"
			else
				_note "Please upgrade OpenSSL"
				ActionTest[$1]="echo ${ActionTest[$1]} $2"
				_upgrade_openssl_string $1 "$(_swinstall OpenSSL)"
			fi
			;;
		"B.11.23")
			grep -q -E 'A.02.00-0.9.7c' $TMPFILE
			if [ $? -eq 0 ]; then
				_note "OpenSSL,r=A.02.00-0.9.7c must be removed"
				ActionTest[$1]="echo ${ActionTest[$1]} $2"
				_upgrade_openssl_string $1 "$(_swremove OpenSSL,r=A.02.00-0.9.7c)"
			fi

			$SWLIST [Oo]pen[Ss][Ss][Ll],r\>=A.00.09.07e.013 >/dev/null 2>&1
			CODE=$?
			if [ $CODE -eq 0 ]; then
				_note "OpenSSL version is OK"
				ActionTest[$1]="echo ${ActionTest[$1]} $2 - OK"
			else
				_note "Please upgrade OpenSSL"
				ActionTest[$1]="echo ${ActionTest[$1]} $2"
				_upgrade_openssl_string $1 "$(_swinstall OpenSSL)"
			fi
			;;
		"B.11.31")
			grep -q -E 'A.02.00-0.9.7c' $TMPFILE
			if [ $? -eq 0 ]; then
				_note "OpenSSL,r=A.02.00-0.9.7c must be removed"
				ActionTest[$1]="echo ${ActionTest[$1]}"
				_upgrade_openssl_string $1 "$(_swremove OpenSSL,r=A.02.00-0.9.7c)"
			fi
			$SWLIST [Oo]pen[Ss][Ss][Ll],r\>=A.00.09.08r.003 >/dev/null 2>&1
			CODE=$?
			if [ $CODE -eq 0 ]; then
				_note "OpenSSL version is OK"
				ActionTest[$1]="echo ${ActionTest[$1]} $2 - OK"
			else
				_note "Please upgrade OpenSSL"
				ActionTest[$1]="echo ${ActionTest[$1]} $2"
				_upgrade_openssl_string $1 "$(_swinstall OpenSSL)"
			fi
			;;
	esac
	rm -f $TMPFILE
}

function _upgrade_openssl_string {
	ActionTest[$1]="${ActionTest[$1]} \n
	grep icapd /etc/inittab | grep -q -v ^# && /sbin/init.d/icod stop \n
	cimserver -s \n
	/sbin/init.d/secsh stop \n
	/sbin/init.d/hpsmh stop \n
	[ -x /sbin/init.d/sfmdb ] && /sbin/init.d/sfmdb stop \n
	[ -x /sbin/init.d/psbdb ] && /sbin/init.d/psbdb stop \n
	sleep 10 \n
	$2 \n
	[ -x /sbin/init.d/sfmdb ] && /sbin/init.d/sfmdb start \n
	[ -x /sbin/init.d/psbdb ] && /sbin/init.d/psbdb start \n
	/sbin/init.d/hpsmh autostart \n
	/sbin/init.d/secsh start \n
	cimserver \n
	grep icapd /etc/inittab | grep -q -v ^# && /sbin/init.d/icod start"
}

function _check_wbem {
	case ${OSver} in
		"B.11.11")
			$SWLIST WBEMServices,r\>=A.02.07.06 >/dev/null 2>&1
			CODE=$?
			;;
		"B.11.23")
			$SWLIST WBEMServices,r\>=A.02.07.04 >/dev/null 2>&1
			CODE=$?
			;;
		"B.11.31")
			$SWLIST WBEMServices,r\>=A.02.09 >/dev/null 2>&1
			CODE=$?
			;;
	esac
	if [ $CODE -eq 0 ]; then
		_note "WBEMService is OK"
		ActionTest[$1]="echo ${ActionTest[$1]} $2 - OK"
	else
		case ${OSver} in
			"B.11.11"|"B.11.23")
				_note "Please upgrade WBEMServices"
				ActionTest[$1]="echo ${ActionTest[$1]} $2 \n
				$(_swinstall WBEMSvcs)"
				;;
			*)
				_note "WBEMServices will be installed via WBEMMgmtBundle"
				ActionTest[$1]="echo ${ActionTest[$1]} $2 - N/A"
				;;
		esac
	fi
}

function _check_WBEMextras {
	# install the WBEMextras product (if required)
	$SWLIST WBEMextras,r\>=A.01.00.04 >/dev/null 2>&1
	CODE=$?
	if [ $CODE -eq 0 ]; then
		_note "WBEMextras is OK"
		ActionTest[$1]="echo ${ActionTest[$1]} $2 - OK"
	else
		ActionTest[$1]="echo ${ActionTest[$1]} $2 \n# Install WBEMextras\n
		$(_swinstall WBEMextras)"
	fi
}

function _check_onlinediag {
	case ${OSver} in
		"B.11.11")
			$SWLIST Sup-Tool-Mgr,r\>=B.11.11.21.04 >/dev/null 2>&1
			CODE=$?
			if [ $CODE -eq 0 ]; then
				# check if version  EMS-Config.EMS-GUI,r=A.04.20.11
				r=`$SWLIST -l fileset EMS-Config.EMS-GUI | tail -1 | awk '{print $2}'`
				if [ "$r" = "A.04.20.11" ]; then
					_note "EMS-Config.EMS-GUI version is too low - force an upgrade"
					CODE=1
				fi
			fi
			;;
		"B.11.23")
			$SWLIST Sup-Tool-Mgr,r\>=B.11.23.13.02 >/dev/null 2>&1
			CODE=$?
			;;
		"B.11.31")
			$SWLIST Sup-Tool-Mgr,r\>=B.11.31.06.05 >/dev/null 2>&1
			CODE=$?
			;;
	esac
	if [ $CODE -eq 0 ]; then
		_note "OnlineDiag version is OK"
		ActionTest[$1]="echo ${ActionTest[$1]} $2 - OK"
	else
		_note "Upgrade of OnlineDiag required"
		ActionTest[$1]="echo ${ActionTest[$1]} $2 \n"
		if [ "${OSver}" = "B.11.11" ]; then
			ActionTest[$1]="${ActionTest[$1]} \n
			# To avoid version conflict with stm gui we remove the EMS Dev Kit first \n
			$(_swremove B7611BA) \n
			$(_swremove EMS-DiskMonitor) \n
			$(_swremove EMS-MIBMonitor) \n
			# We force an installation of OnlineDiag now \n"
		fi # end of "B.11.11"
		ActionTest[$1]="${ActionTest[$1]}
		$(_swinstall OnlineDiag "-x autoreboot=true") "
	fi

}

function _check_sysmgmtweb {
	$SWLIST SysMgmtWeb,r\>=A.2.2.9  >/dev/null 2>&1
	CODE=$?
	if [ $CODE -eq 0 ]; then
		_note "System Management Homepage version is OK"
		ActionTest[$1]="echo ${ActionTest[$1]} $2 - OK"
	else
		_note "Please upgrade System Management Homepage"
		ActionTest[$1]="echo ${ActionTest[$1]} $2 \n
		$(_swinstall SysMgmtWeb)"
	fi
}

function _check_apache20 {
	case ${OSver} in
		"B.11.11")
			$SWLIST hpuxwsApache,r\>=A.2.0.59 >/dev/null 2>$TMPFILE
			CODE=$?
			;;
		"B.11.23")
			$SWLIST hpuxwsApache,r\>=A.2.0.59 >/dev/null 2>$TMPFILE
			CODE=$?
			;;
		"B.11.31")
			$SWLIST hpuxwsApache,r\>=A.2.0.59 >/dev/null 2>$TMPFILE
			CODE=$?
			;;
	esac

	grep -q "not found" $TMPFILE && CODE=2

	case $CODE in
		0)
		_note "hpuxwsApache release is OK"
		ActionTest[$1]="echo ${ActionTest[$1]} $2 - OK"
		;;
		1)
		if [ "${OSver}" = "B.11.31" ]; then
			_note "hpuxwsApache A.2.0.x is out of support - N/A"
			ActionTest[$1]="echo ${ActionTest[$1]} $2 - N/A"
		else
			_note "Upgrade of hpuxwsApache is required"
			ActionTest[$1]="echo ${ActionTest[$1]} $2 \n
			$(_swinstall hpuxwsApache)"
		fi
		;;
		2)
		if [ "${OSver}" = "B.11.31" ]; then
			_note "hpuxwsApache A.2.0.x was not found and is out of support - N/A"
			ActionTest[$1]="echo ${ActionTest[$1]} $2 - N/A"
		else
			_note "hpuxwsApache A.2.0.x was not found - installing it"
			ActionTest[$1]="echo ${ActionTest[$1]} $2 \n
			$(_swinstall hpuxwsApache)"
		fi
		;;
	esac
	rm -f $TMPFILE
}

function _check_apache22 {
	case ${OSver} in
		"B.11.11")
			$SWLIST hpuxws22[aA][pP][aA][cC][hH][eE],r\>=A.2.0.59 >/dev/null 2>$TMPFILE
			CODE=$?
			;;
		"B.11.23")
			$SWLIST hpuxws22[aA][pP][aA][cC][hH][eE],r\>=A.2.2.15.10 >/dev/null 2>$TMPFILE
			CODE=$?
			;;
		"B.11.31")
			$SWLIST hpuxws22[aA][pP][aA][cC][hH][eE],r\>=B.2.2.15.06 >/dev/null 2>$TMPFILE
			CODE=$?
			;;
	esac

	grep -q "not found" $TMPFILE && CODE=2

	case $CODE in
		0)
		_note "hpuxws22Apache release is OK"
		ActionTest[$1]="echo ${ActionTest[$1]} $2 - OK"
		;;
		1)
		_note "Upgrade of hpuxws22Apache is required"
		ActionTest[$1]="echo ${ActionTest[$1]} $2 \n
		$(_swinstall hpuxws22Apache) \n
		$(_swinstall hpuxws22Tomcat) \n
		$(_swinstall hpuxws22Webmin)"
		;;
		2) # hpuxws22Apache was not found
		$SWLIST -s ${IUXSERVER}:${baseDepo}/$os hpuxws22[aA][pP][aA][cC][hH][eE]  >/dev/null 2>&1
		if [ $? -eq 0 ]; then
			# OK, we have Apache 2.2 available on our central depot
			_note "Installing latest Apache Web-server version 2.2.x"
			ActionTest[$1]="echo ${ActionTest[$1]} $2 \n
			$(_swinstall hpuxws22Apache) \n
			$(_swinstall hpuxws22Tomcat) \n
			$(_swinstall hpuxws22Webmin)"
		else
			_note "hpuxws22Apache release not found - N/A"
			ActionTest[$1]="echo ${ActionTest[$1]} $2 - N/A"
		fi
		;;
	esac
	rm -f $TMPFILE
}

function _check_sfm {
	case ${OSver} in
		"B.11.11")
			$SWLIST SysFaultMgmt,r\>=A.04.02.01.05  >/dev/null 2>&1
			CODE=$?
			;;
		"B.11.23")
			$SWLIST SysFaultMgmt,r\>=B.07.05.01.02  >/dev/null 2>&1
			CODE=$?
			;;
		"B.11.31")
			$SWLIST SysFaultMgmt,r\>=C.07.04.06.01  >/dev/null 2>&1
			CODE=na		# ignore as it will be installed via WBEMMgmtBundle
			;;
	esac
	case $CODE in
		"0")
			_note "System Fault Management (SFM) is OK"
			ActionTest[$1]="echo ${ActionTest[$1]} $2 - OK"
			;;
		"1")
			_note "(Re-)Install of System Fault Management (SFM) is required"
			ActionTest[$1]="echo ${ActionTest[$1]} $2 \n
			$(_swinstall SysFaultMgmt "-x autoreboot=true -x reinstall=false") "
			;;
		"na")
			_note "System Fault Management (SFM) will be installed via WBEMMgmtBundle"
			 ActionTest[$1]="echo ${ActionTest[$1]} $2 - N/A"
			;;
	esac

	# Check if SysFaultMgmt was correctly configured
	ActionTest[$1]="${ActionTest[$1]} \n
$SWLIST -l fileset -a state SysFaultMgmt | grep -v -E '\#|configured' | grep  'installed' \n
if [ \$? -eq 0 ]; then \n
	$(_swconfig SysFaultMgmt) \n
fi"
}

function _check_WBEMMgmtBundle {
	# only required for HP-UX 11.31
	CODE=0
	case ${OSver} in
		"B.11.31")
			$SWLIST WBEMMgmtBundle,r\>=C.02.01 >/dev/null 2>&1
			CODE=$?
			;;
		*)	CODE=na
			;;
	esac
	case "$CODE" in
		"na")	_note "WBEMMgmtBundle is not required on $os - N/A"
			ActionTest[$1]="echo ${ActionTest[$1]} $2 - N/A"
			;;
		"0")	_note "WBEMMgmtBundle is OK"
			ActionTest[$1]="echo ${ActionTest[$1]} $2 - OK"
			;;
		*)	_note "(Re-)Install of WBEMMgmtBundle is required"
			ActionTest[$1]="echo ${ActionTest[$1]} $2 \n
			$(_swinstall "WBEMMgmtBundle CommonIO SysMgmtPlus" "-x autoreboot=true -x reinstall=false") " 
			;;
	esac
}

function _check_rsp_patches {
	case ${OSver} in
		"B.11.11") # no special patches required for RSP on HP-UX 11.11
			_note "No IRSA patch bundle for HP-UX 11.11 required"
			 ActionTest[$1]="echo ${ActionTest[$1]} $2 - OK"
			;;
		"B.11.23") # special patch bundle needed
			$SWLIST WBEMpatches-1123,r\>=B.2011.12.13 >/dev/null 2>&1
			CODE=$?
			if [ $CODE -ne 0 ]; then
				_note "Apply IRSA patch bundle for HP-UX 11.23"
				ActionTest[$1]="echo ${ActionTest[$1]} $2 \n
				$(_swinstall WBEMpatches-1123 "-x patch_match_target=true  -x autoreboot=true") "
			else
				_note "IRSA patch bundle for HP-UX 11.23 already present"
				ActionTest[$1]="echo ${ActionTest[$1]} $2 - OK"
			fi
			;;
		"B.11.31") # no special patches required for RSP on HP-UX 11.31
			_note "No IRSA patch bundle for HP-UX 11.31 required"
			 ActionTest[$1]="echo ${ActionTest[$1]} $2 - OK"
			;;
	esac
}

function _check_ISEEPlatform {
	grep -q -E 'ISEEPlatform' $TMPFILE
	if [ $? -eq 0 ]; then
		_note "ISEEPlatform must be removed"
		ActionTest[$1]="echo ${ActionTest[$1]} $2 \n
		$(_swremove ISEEPlatform)"
	else
		_note "ISEEPlatform was not found - OK"
		ActionTest[$1]="echo ${ActionTest[$1]} $2 - OK"
	fi
	rm -f $TMPFILE
}

function _check_old_SFM {
	CODE=0
	# CODE=0 means OK; CODE=1 means version too low or not installed
	case ${OSver} in
		"B.11.11") # remove if version of SFM is too old
			$SWLIST SysFaultMgmt,r\>=A.04.02.01.05 >/dev/null 2>&1
			CODE=$?
			;;	
		"B.11.23")
			$SWLIST SysFaultMgmt,r\>=B.07.05.01.02 >/dev/null 2>&1
			CODE=$?
			;;
		"B.11.31")
			$SWLIST SysFaultMgmt,r\>=C.07.04.06.01 >/dev/null 2>&1
			CODE=$?
			;;
	esac

	$SWLIST SysFaultMgmt >/dev/null 2>$TMPFILE	# perhaps SFM was not installed
	grep -q "was not found" $TMPFILE && CODE=2

	case $CODE in
		0)
			_note "Current SysFaultMgmt version is OK"
			ActionTest[$1]="echo ${ActionTest[$1]} $2 - OK"
			;;
		1)
			_note "SysFaultMgmt will be upgraded (later)"
			ActionTest[$1]="echo ${ActionTest[$1]} $2 - N/A"
			;;
		2)
			_note "SysFaultMgmt was not found (will be installed later)"
			ActionTest[$1]="echo ${ActionTest[$1]} $2 - N/A"
			;;
	esac

	rm -f $TMPFILE
}

function _check_old_ProviderSvcsCore {
	# only for HP-UX 11.31 where PostgreSQL was moved to here instead of SFM
	CODE=0
	case ${OSver} in
		"B.11.31")
			$SWLIST ProviderSvcsCore,r\>=C.06.00.04 >/dev/null 2>$TMPFILE
			CODE=$?
			grep -q "was not found" $TMPFILE && CODE=2
			;;
		*)	CODE=na
			;;
	esac


	case "$CODE" in
		"0")
			_note "Current ProviderSvcsCore version is OK"
			ActionTest[$1]="echo ${ActionTest[$1]} $2 - OK"
			;;
		"1")
			_note "ProviderSvcsCore must be removed (will be re-installed later)"
			ActionTest[$1]="echo ${ActionTest[$1]} $2 \n
			$(_swremove ProviderSvcsCore)"
			;;
		"2")
			_note "ProviderSvcsCore was not found (will be installed later)"
			ActionTest[$1]="echo ${ActionTest[$1]} $2 - N/A"
			;;
		"na")
			_note "ProviderSvcsCore is not required on $os - N/A"
			ActionTest[$1]="echo ${ActionTest[$1]} $2 - N/A"
			;;
	esac
	rm -f $TMPFILE
}

function _install_rs_acc {
	ActionTest[$1]="echo ${ActionTest[$1]} $2"
	$SWLIST RS-ACC,r\>=A.05.50 >/dev/null 2>&1
	CODE=$?
	if [ $CODE -ne 0 ]; then
		_note "Install HP Remote Support Advanced Configuration Collector"
        	ActionTest[$1]="${ActionTest[$1]} \n
		$(_swinstall RS-ACC)"
	else
		_note "HP Remote Support Advanced Configuration Collector version is OK"
		ActionTest[$1]="${ActionTest[$1]} - OK"
	fi
}

function _check_nParProvider {
        case ${OSver} in
                "B.11.11")
			$SWLIST nParProvider,r\>=B.12.02.07.03 >/dev/null 2>&1
			CODE=$?
                        ;;
                "B.11.23")
			$SWLIST nParProvider,r\>=B.23.01.07.05 >/dev/null 2>&1
			CODE=$?
                        ;;
                "B.11.31")
			$SWLIST nParProvider,r\>=B.31.02.01 >/dev/null 2>&1
			CODE=na
                        ;;
        esac
	case $CODE in
		"0")
			_note "nParProvider version is OK"
			ActionTest[$1]="echo ${ActionTest[$1]} $2 - OK"
			;;
		"1")
		 	_note "Install or Update nParProvider"
		 	ActionTest[$1]="echo ${ActionTest[$1]} $2 \n
			$(_swinstall nParProvider)"
			;;
		"na")
			_note "nParProvider is part of WBEMMgmtBundle"
			ActionTest[$1]="echo ${ActionTest[$1]} $2 - NA"
			;;
	esac
}

function _check_vParProvider {
        case ${OSver} in
                "B.11.11")
			$SWLIST vParProvider,r\>=B.11.11.01.06 >/dev/null 2>&1
			CODE=$?
                        ;;
                "B.11.23")
			$SWLIST vParProvider,r\>=B.11.23.01.07 >/dev/null 2>&1
			CODE=$?
                        ;;
                "B.11.31")
			$SWLIST vParProvider,r\>=B.11.31.01.05 >/dev/null 2>&1
			CODE=na
                        ;;
        esac
	case $CODE in
		"0")
			_note "vParProvider version is OK"
			ActionTest[$1]="echo ${ActionTest[$1]} $2 - OK"
			;;
		"1")
		 	_note "Install or Update vParProvider"
		 	ActionTest[$1]="echo ${ActionTest[$1]} $2 \n
			$(_swinstall vParProvider)"
			;;
		"na")
			_note "vParProvider is part of WBEMMgmtBundle"
			ActionTest[$1]="echo ${ActionTest[$1]} $2 - NA"
			;;
	esac
}

function _swconfig_CIM_providers {
	_note "(Re-)Configure all CIM Providers installed on this system"
	ActionTest[$1]="echo ${ActionTest[$1]} $2"
	$SWLIST FCProvider >/dev/null 2>&1
	if [ $? -eq 0 ]; then
	   ActionTest[$1]="${ActionTest[$1]} \n
	   $(_swconfig FCProvider)"
	fi
	$SWLIST FileSysProvider >/dev/null 2>&1
	if [ $? -eq 0 ]; then
	   ActionTest[$1]="${ActionTest[$1]} \n
	   $(_swconfig FileSysProvider)"
	fi
	$SWLIST IOTreeIndication >/dev/null 2>&1
	if [ $? -eq 0 ]; then
	   ActionTest[$1]="${ActionTest[$1]} \n
	   $(_swconfig IOTreeIndication)"
	fi
	$SWLIST IOTreeProvider >/dev/null 2>&1
	if [ $? -eq 0 ]; then
	   ActionTest[$1]="${ActionTest[$1]} \n
	   $(_swconfig IOTreeProvider)"
	fi
	$SWLIST LVMProvider >/dev/null 2>&1
	if [ $? -eq 0 ]; then
	   ActionTest[$1]="${ActionTest[$1]} \n
	   $(_swconfig LVMProvider)"
	fi
	$SWLIST SCSIProvider >/dev/null 2>&1
	if [ $? -eq 0 ]; then
	   ActionTest[$1]="${ActionTest[$1]} \n
	   $(_swconfig SCSIProvider)"
	fi
	$SWLIST UtilProvider >/dev/null 2>&1
	if [ $? -eq 0 ]; then
	   ActionTest[$1]="${ActionTest[$1]} \n
	   $(_swconfig UtilProvider)"
	fi
	$SWLIST WBEMP-LAN-00 >/dev/null 2>&1
	if [ $? -eq 0 ]; then
	   ActionTest[$1]="${ActionTest[$1]} \n
	   $(_swconfig WBEMP-LAN-00)"
	fi
	$SWLIST nParProvider >/dev/null 2>&1
	if [ $? -eq 0 ]; then
	   ActionTest[$1]="${ActionTest[$1]} \n
	   $(_swconfig nParProvider)"
	fi
	$SWLIST vParProvider >/dev/null 2>&1
	if [ $? -eq 0 ]; then
	   ActionTest[$1]="${ActionTest[$1]} \n
	   $(_swconfig vParProvider)"
	fi
	$SWLIST KernelProviders >/dev/null 2>&1
	if [ $? -eq 0 ]; then
	   ActionTest[$1]="${ActionTest[$1]} \n
	   $(_swconfig KernelProviders)"
	fi
	$SWLIST RAIDSAProvider >/dev/null 2>&1
	if [ $? -eq 0 ]; then
	   ActionTest[$1]="${ActionTest[$1]} \n
	   $(_swconfig RAIDSAProvider)"
	fi
	$SWLIST SASProvider >/dev/null 2>&1
	if [ $? -eq 0 ]; then
	   ActionTest[$1]="${ActionTest[$1]} \n
	   $(_swconfig SASProvider)"
	fi
	$SWLIST VMProvider >/dev/null 2>&1
	if [ $? -eq 0 ]; then
	   ActionTest[$1]="${ActionTest[$1]} \n
	   $(_swconfig VMProvider)"
	fi
	$SWLIST DASProvider >/dev/null 2>&1
	if [ $? -eq 0 ]; then
	   ActionTest[$1]="${ActionTest[$1]} \n
	   $(_swconfig DASProvider)"
	fi
	$SWLIST OLOSProvider >/dev/null 2>&1
	if [ $? -eq 0 ]; then
	   ActionTest[$1]="${ActionTest[$1]} \n
	   $(_swconfig OLOSProvider)"
	fi
	$SWLIST ProviderSvcsCore >/dev/null 2>&1
	if [ $? -eq 0 ]; then
	   ActionTest[$1]="${ActionTest[$1]} \n
	   $(_swconfig ProviderSvcsCore)"
	fi
	$SWLIST CM-Provider-MOF >/dev/null 2>&1
	if [ $? -eq 0 ]; then
	   ActionTest[$1]="${ActionTest[$1]} \n
	   $(_swconfig CM-Provider-MOF)"
	fi
	$SWLIST OPS-Provider-MOF >/dev/null 2>&1
	if [ $? -eq 0 ]; then
	   ActionTest[$1]="${ActionTest[$1]} \n
	   $(_swconfig OPS-Provider-MOF)"
	fi
	$SWLIST WBEMP-LAN >/dev/null 2>&1
	if [ $? -eq 0 ]; then
	   ActionTest[$1]="${ActionTest[$1]} \n
	   $(_swconfig WBEMP-LAN)"
	fi
	# final steps SW-DIST and SFM-CORE
	ActionTest[$1]="${ActionTest[$1]} \n
	$(_swconfig SW-DIST) \n
	$(_swconfig SFM-CORE)"
######## END of Test - swconfig of CIM Providers ##############
}

function _stop_hpsmh {
	# Stop the HP smh daemon(s)
	_note "Stop the HP System Mgmt Homepage daemon"
	ActionTest[$1]="echo ${ActionTest[$1]} $2 \n
/sbin/init.d/hpsmh stop"
}

function _start_hpsmh {
	# Start the HP smh daemon(s)
	_note "Start the HP System Mgmt Homepage daemon"
	ActionTest[$1]="echo ${ActionTest[$1]} $2 \n
/sbin/init.d/hpsmh start"
}

function _check_xxx {
	case ${OSver} in
		"B.11.11")
			;;
		"B.11.23")
			;;
		"B.11.31")
			;;
	esac
}

function _revision {
	typeset rev
	rev=$(awk '/\$Revision:/ { print $3 }' $PRGDIR/$PRGNAME | head -1 | sed -e 's/\$//')
	[ -n "$rev" ] || rev="UNKNOWN"
	echo $rev
}

function _line {
	typeset -i i
	while (( i < ${1:-80} )); do
		(( i+=1 ))
		echo "=\c"
	done
	echo
}

function _check_install_log_for_errors {
	PrNxLn=0
	FoundError=0
	grep -E 'ERROR|swjob' $dlog/`basename ${ISCRIPT%???}`-install.scriptlog | \
        { while read Line
        do
                echo $Line | grep -q ERROR
                if [ $? -eq 0 ]; then
                	echo "==> $Line"
                        PrNxLn=1
			FoundError=1
			EXITCODE=$((EXITCODE + 1))	# count the amount of errors
			continue
                fi
                if [ $PrNxLn -eq 1 ]; then
			echo "==> Run $Line"
                        echo $Line | grep -q swjob
			if [ $? -eq 0 ]; then
			echo $Line | sed -e 's/command//' -e 's/\.$//' -e 's/"//g' | sh -
			fi
			PrNxLn=0
                fi
        done
        }
	if [ $FoundError -eq 0 ]; then
		_note "No errors found in install log file."
	fi
}

function _check_config_log_for_errors {
	FoundError=0
	grep -E 'ERROR|not found|FAILED' $dlog/`basename ${CSCRIPT%???}`-config.scriptlog | \
	{ while read Line
	do
		echo "==> $Line"
		echo $Line | grep -q CIM_ERR_FAILED && {
			echo "The CIM_ERR_FAILED error means the user authorisations were already in place - ignore it"
		}
		echo $Line | grep -q "not found" && {
			echo "Executable not found: $Line"
		}
		echo $Line | grep -q  "ERROR" && {
			echo "Please investigate the error."
			EXITCODE=$((EXITCODE + 1))	# count the amount of errors
			FoundError=1
		}
	done
	}
	if [ $FoundError -eq 0 ]; then
		_note "No errors found in config log file."
	fi
}

function _ask_for_password {
	# here we will interactively prompt for password for user WbemUser
	# we can only do this if we run in interactive mode of course
	typeset -i correctPW=1
	while [ $correctPW -ne 0 ]; do
	if [ $(tty -s; echo $?) ]; then
		echo "Enter the secret password for user $WbemUser (do not forget it!)"
		ENCPW=$(openssl passwd -crypt)
		correctPW=$?
	else
		echo "Using the default password for user $WbemUser"	
		correctPW=0
	fi
	done
}

function _ping_system {
	# one parameter: system to ping
	typeset svr=$1
	case $(ping ${svr} -n 1) in
		*', 0% packet loss'* )	return 0 ;;	# Everything is OK
		* )			return 1 ;;	# We got other than 0% packet loss
	esac
}

function _check_patches_11_11 {
	/usr/sbin/swlist BUNDLE11i,r\>=B.11.11.0306  >/dev/null  2>&1
	CODE=${?}
	if [ ${CODE} -ne 0 ]; then
		# This is going to get a bit rough in explaination.
		# The BUNDLE11i Revision B.11.11.03.06.1 contains the
		# following patches. We noted we don't meet the BUNDLE11i
		# definition at the top level, now we are checking to see
		# if we meet the details of BUNDLE11i,r>=B.11.11.0306 by
		# checking each and every patch in that bundle and ensuring
		# that it, or a superseding patch, is installed on this
		# machine. IF we do meet the detailed test, we remain
		# silent, if we don't we suggest the update of BUNDLE11i
		# and don't get into which patch(es) are missing.
		#
		# Note we skipped PHCO_23340 because it doens't always
		# install if SD-DIST was updated to B.11.11.0409
		CODE=0
		BUNDLE11iNEEDED=0
		for i in           PHNE_23289 PHNE_23288 PHKL_23316 \
			PHKL_23315 PHKL_23314 PHKL_23313 PHKL_23312 \
			PHKL_23311 PHKL_23310 PHKL_23309 PHKL_23308 \
			PHKL_23307 PHKL_23306 PHKL_23305 PHKL_23304 \
			PHKL_23303 PHKL_23302 PHKL_23301 PHKL_23300 \
			PHKL_23299 PHKL_23298 PHKL_23297 PHKL_23296 \
			PHKL_23295 PHKL_23294 PHKL_23293 PHKL_23292 \
			PHKL_23291 PHKL_23290 PHCO_28160
		do
			swlist -l fileset -a supersedes | grep -q ${i}
			CODE=${?}
			if [ ${CODE} -ne 0 ]; then
				_note "WARNING: ${i} (or a supersede) is missing from BUNDLE11i"
				BUNDLE11iNEEDED=1
			fi
		done
	fi

}

function _check_patches_11_23 {
	/usr/sbin/swlist HPUX11i-OE\*,r\>=B.11.23.0409  >/dev/null  2>&1
	CODE=${?}
	if [ ${CODE} -ne 0 ]; then
		BUNDLE11iNEEDED=0
		for i in PHCO_30312 PHCO_31540 PHCO_31541 PHCO_31542 \
			PHCO_31543 PHCO_31544 PHCO_31545 PHCO_31546 \
			PHCO_31547 PHCO_31548 PHCO_31549 PHCO_31550 \
			PHCO_31551 PHCO_31552 PHCO_31553 PHCO_31554 \
			PHCO_31555 PHCO_31556 PHCO_31557 PHCO_31558 \
			PHCO_31559 PHCO_31560 PHCO_31561 PHCO_31562 \
			PHCO_31563 PHCO_31564 PHCO_31565 PHCO_31566 \
			PHCO_31567 PHCO_31568 PHCO_31569 PHCO_31570 \
			PHCO_31571 PHCO_31572 PHCO_31573 PHCO_31574 \
			PHCO_31575 PHCO_31576 PHCO_31577 PHCO_31578 \
			PHCO_31579 PHCO_31580 PHCO_31581 PHCO_31582 \
			PHCO_31583 PHCO_31584 PHCO_31585 PHCO_31586 \
			PHCO_31587 PHCO_31588 PHCO_31589 PHCO_31590 \
			PHCO_31591 PHCO_31592 PHCO_31593 PHCO_31594 \
			PHCO_31595 PHCO_31597 PHCO_31598 PHCO_31599 \
			PHCO_31600 PHCO_31601 PHCO_31602 PHCO_31603 \
			PHCO_31604 PHCO_31605 PHCO_31606 PHCO_31607 \
			PHCO_31608 PHCO_31609 PHCO_31611 PHCO_31612 \
			PHCO_31613 PHCO_31614 PHCO_31615 PHCO_31616 \
			PHCO_31617 PHCO_31618 PHCO_31619 PHCO_31620 \
			PHCO_31621 PHCO_31622 PHCO_31623 PHCO_31624 \
			PHCO_31625 PHCO_31626 PHCO_31627 PHCO_31628 \
			PHCO_31629 PHCO_31630 PHCO_31632 PHCO_31633 \
			PHCO_31634 PHCO_31635 PHCO_31636 PHCO_31637 \
			PHCO_31638 PHCO_31639 PHCO_31640 PHCO_31641 \
			PHCO_31642 PHCO_31643 PHCO_31644 PHCO_31645 \
			PHCO_31646 PHCO_31647 PHCO_31648 PHCO_31649 \
			PHCO_31650 PHCO_31651 PHCO_31652 PHCO_31653 \
			PHCO_31654 PHCO_31655 PHCO_31656 PHCO_31657 \
			PHCO_31658 PHCO_31659 PHCO_31660 PHCO_31661 \
			PHCO_31662 PHCO_31663 PHCO_31664 PHCO_31665 \
			PHCO_31666 PHCO_31667 PHCO_31668 PHCO_31669 \
			PHCO_31670 PHCO_31671 PHCO_31672 PHCO_31673 \
			PHCO_31674 PHCO_31675 PHCO_31676 PHCO_31677 \
			PHCO_31678 PHCO_31679 PHCO_31680 PHCO_31681 \
			PHCO_31682 PHCO_31683 PHCO_31684 PHCO_31685 \
			PHCO_31686 PHCO_31687 PHCO_31688 PHCO_31689 \
			PHCO_31690 PHCO_31691 PHCO_31692 PHCO_31693 \
			PHCO_31694 PHCO_31695 PHCO_31696 PHCO_31697 \
			PHCO_31698 PHCO_31699 PHCO_31700 PHCO_31701 \
			PHCO_31702 PHCO_31703 PHCO_31704 PHCO_31705 \
			PHCO_31706 PHCO_31708 PHCO_31709 PHCO_31710 \
			PHCO_31711 PHCO_31820 PHCO_31848 PHKL_31500 \
			PHKL_31501 PHKL_31502 PHKL_31503 PHKL_31504 \
			PHKL_31506 PHKL_31507 PHKL_31508 PHKL_31510 \
			PHKL_31511 PHKL_31512 PHKL_31513 PHKL_31515 \
			PHKL_31517 PHNE_31725 PHNE_31726 PHNE_31727 \
			PHNE_31731 PHNE_31732 PHNE_31733 PHNE_31734 \
			PHNE_31735 PHNE_31736 PHNE_31737 PHNE_31738 \
			PHNE_31739 PHSS_30414 PHSS_30480 PHSS_30505 \
			PHSS_30601 PHSS_30713 PHSS_30714 PHSS_30715 \
			PHSS_30716 PHSS_30719 PHSS_30771 PHSS_30795 \
			PHSS_30820 PHSS_31087 PHSS_31181 PHSS_31242 \
			PHSS_31755 PHSS_31756 PHSS_31817 PHSS_31819 \
			PHSS_31831 PHSS_31832 PHSS_31833 PHSS_31834 \
			PHSS_31840
		do
			swlist -l fileset -a supersedes | grep -q ${i}
			CODE=${?}
			if [ ${CODE} -ne 0 ]; then
				_note "WARNING: ${i} (or a supersede) is missing from BUNDLE11i"
				BUNDLE11iNEEDED=1
			fi
		done

		if [ "$arch" = "ia64" ]; then
			for i in PHNE_31728 PHSS_29679 PHSS_31086 PHSS_31816
			do
				swlist -l fileset -a supersedes | grep -q ${i}
				CODE=${?}
				if [ ${CODE} -ne 0 ]; then
					_note "WARNING: ${i} (or a supersede) is missing from BUNDLE11i"
					BUNDLE11iNEEDED=1
				fi
			done
		else
			# PA-RISC Platform patches
			for i in PHCO_31596 PHKL_31509 PHSS_30819 PHSS_30891
			do
				swlist -l fileset -a supersedes | grep -q ${i}
				CODE=${?}
				if [ ${CODE} -ne 0 ]; then
					_note "WARNING: ${i} (or a supersede) is missing from BUNDLE11i"
					BUNDLE11iNEEDED=1
				fi
			done
		fi
	fi
}

function _check_special_patches_11_23 {
	for i in PHKL_36288 PHKL_34795 PHKL_33312 PHSS_37947 PHSS_35055
	do
		/usr/sbin/swlist -l fileset -a supersedes | grep -sq ${i}
		CODE=${?}
		if [ ${CODE} -ne 0 ]; then
			_note "WARNING: ${i} or a successor patch is missing."
			WARNFOUND=1
		fi 
	done


	if [ "$arch" = "ia64" ]; then
		for i in PHSS_37552 PHSS_36345
		do
			/usr/sbin/swlist -l fileset -a supersedes | grep -sq ${i}
			CODE=${?}
			if [ ${CODE} -ne 0 ]; then
				_note "WARNING: ${i} or a successor patch is missing."	
				WARNFOUND=1
			fi 
		done 
	fi
}

function _check_patches_11_31 {
	# HP-UX 11.31 doesn't need special patches (yet)
	BUNDLE11iNEEDED=0
}

function hpuxseq {
	# p1=startvalue p2=stopvalue
	if [[ $# -eq 1 ]] ; then
		echo "$1"
		return 0
	fi

	iz=$1
	while [ $iz -le $2 ] ; do echo $iz ; iz=$(expr $iz + 1 ) ; done

	return 0
} # END function hpuxseq

function OS_supported {
	case ${OSver} in
		"B.11.11"|"B.11.23"|"B.11.31")
			_note "HP-UX ${os} support is OK"
			ActionTest[$1]="echo ${ActionTest[$1]} $2 - OK"
			;;
		*)
			ActionTest[$1]="echo ${ActionTest[$1]} $2 - FAIL"
			 _error "HP-UX version ${OSver} of $HOSTNAME is not supported for HP-SIM/RSP"
			;;
	esac
}

function Patch_Level {
	BUNDLE11iNEEDED=0
	WARNFOUND=0
	case ${OSver} in
		"B.11.11") _check_patches_11_11
		   ;;
		"B.11.23") _check_patches_11_23
			   _check_special_patches_11_23
		   ;;
		"B.11.31") _check_patches_11_31
		   ;;
	esac

	if [ $BUNDLE11iNEEDED -eq 1 ]; then
		ActionTest[$1]="echo ${ActionTest[$1]} $2 - FAIL"
		_line
		_note "Cannot continue. Minimum required patches are missing!"
		msg="[CRITICAL] ${PRGNAME}: Minimum required patches are missing on $HOSTNAME"
		_mail "$msg"
		_error "Missing some critical patches on $HOSTNAME! See scriptlog."
	else
		_note "Patch Level is OK"
		ActionTest[$1]="echo ${ActionTest[$1]} $2 - OK"
	fi

	if [ $WARNFOUND -eq 1 ]; then
		_line
		_note "WARNING: It is advisable to install above patches"
	fi
}

function Corrupt_Filesets {
	$SWLIST -l fileset -a state | grep -q 'corrupt'
	CODE=$?
	if [ $CODE -eq 0 ]; then
		ActionTest[$1]="echo ${ActionTest[$1]} $2 - FAIL"
		_line
		_note "Cannot continue. Please remove the corrupt filesets first:"
		$SWLIST -l fileset -a state | grep 'corrupt'
		_line
		msg="[CRITICAL] ${PRGNAME}: Corrupt filesets found on $HOSTNAME"
		_mail "$msg"
		_error "Corrupt filesets found on $HOSTNAME!"
	else
		_note "Corrupt filesets - none were found - OK"
		ActionTest[$1]="echo ${ActionTest[$1]} $2 - N/A"
	fi
}

function _check_HpsmhAdminGroup {
	grep -q ^${HpsmhAdminGroup} /etc/group
	if [ $? -ne 0 ]; then
		_note "Secondary group ${HpsmhAdminGroup} not found, using hpsmh instead"
		HpsmhAdminGroup=hpsmh
	fi
}

function BaseDepo_os_available {
	$SWLIST -s ${sourceDepo} >/dev/null 2>/dev/null
	CODE=$?
	if [ $CODE -eq 0 ]; then
		ActionTest[$1]="echo ${ActionTest[$1]} $2 - OK"
		_note "Depot ${sourceDepo} exists - OK"
	else
		ActionTest[$1]="echo ${ActionTest[$1]} $2 - FAIL"
		_note "Depot ${sourceDepo} not found on ${IUXSERVER} - FAIL"
		if [[ $INSTALL_MODE = 1 ]]; then
			# in installation mode we stop here
			exit 1
		fi
	fi
}

# -----------------------------------------------------------------------------
#                              Setting up the default values
# -----------------------------------------------------------------------------
typeset IUXSERVER mailusr SimServer	# defaults are empty
typeset WbemUser=wbem
typeset HpsmhAdminGroup=hpsmh
typeset baseDepo=/var/opt/ignite/depots/GLOBAL/rsp/pre-req
int INSTALL_MODE=0		# default preview mode
typeset dlog=/var/adm/install-logs                   # Log directory
# ENCPW contains encrypted password of the wbem user (used for wbem subscription with hp sim)
# An easy way to produce such crypt password is with "openssl passwd -crypt"
# To change this password interactively use the "-p" option (without password!)
ENCPW="6u2CMymnCznQo"           # default password is "hpinvent" (without the double quotes)
typeset ConfFile=/usr/local/etc/HPSIM_irsa.conf		# default configuration file

# -----------------------------------------------------------------------------
_whoami				# must be root to continue
# -----------------------------------------------------------------------------

# -----------------------------------------------------------------------------
#                               Config file
# -----------------------------------------------------------------------------
if [ -f $ConfFile ]; then
        _note "Reading configuration file $ConfFile"
        . $ConfFile || _error "Problem with dotting $ConfFile (perhaps DOS format?)"
fi


# -----------------------------------------------------------------------------
#                              Setting up options
# -----------------------------------------------------------------------------
while getopts ":u:g:d:m:c:s:hpvi" opt; do
	case $opt in
		u) WbemUser="$OPTARG" ;;
		g) HpsmhAdminGroup="$OPTARG"
		   _check_HpsmhAdminGroup ;;
		d) installation_path="$OPTARG"
		   _define_installation_path
		   ;;
		m) mailusr="$OPTARG" ;;
		h) _msg; echo; exit 2 ;;
		p) _ask_for_password ;;
		v) _revision; exit ;;
		s) SimServer="$OPTARG" ;;
		i) INSTALL_MODE=1 ;;
		c) ConfFile="$OPTARG"
		   [ -f $ConfFile ] && . $ConfFile
		   ;;
		:)
			_note "Missing argument.\n"
			_shortMsg; echo; exit 2
			;;
		\?) _shortMsg; echo; exit 2 ;;
	esac
done

shift $(( OPTIND - 1 ))

# -----------------------------------------------------------------------------
#				Some sanity checks
# -----------------------------------------------------------------------------
if [[ -z $IUXSERVER ]]; then
	_netRegion	# try to figure out which IUXSERVER to use
fi

# is our ignite server (or SD server) reachable?
if _ping_system "$IUXSERVER" ; then
	_note "Software Depot server $IUXSERVER is reachable"
else
	_error "System $IUXSERVER is not reachable via ping from $HOSTNAME"
	exit 2
fi

# -----------------------------------------------------------------------------
#				For debugging purposes
# -----------------------------------------------------------------------------
#typeset -ft _whoami
#typeset -ft _error
#typeset -ft _note
#typeset -ft _check_openssl
#typeset -ft _check_wbem
#typeset -ft _check_onlinediag
#typeset -ft _check_sysmgmtweb
#typeset -ft _check_apache
#typeset -ft _check_sfm

# -----------------------------------------------------------------------------
#				M A I N  body
# -----------------------------------------------------------------------------

if [[ ! -d $dlog ]]; then
        _note "$PRGNAME ($LINENO): [$dlog] does not exist."
        print -- "     -- creating now: \c"

        mkdir -p $dlog && echo "[  OK  ]" || {
                echo "[FAILED]"
                _note "Could not create [$dlog]. Exiting now"
                _mail "$PRGNAME: ERROR - Could not create [$dlog] on $HOSTNAME"
                exit 1
        }
fi

# define instlog here as dlog might have changed via ConfFile
typeset instlog=$dlog/${PRGNAME%???}.$(date +'%Y-%m-%d.%H%M%S').scriptlog

######### here we really start logging ############
{		# log everything from here to the last } in $instlog

_line
echo "  Installation Script: $PRGNAME"
[[ "$(_revision)" = "UNKNOWN" ]] ||  echo "             Revision: $(_revision)"
echo "        Ignite Server: $IUXSERVER"
echo "           OS Release: $os"
echo "                Model: $(model)"
echo "    Installation Host: $HOSTNAME"
echo "    Installation User: $(whoami)"
echo "    Installation Date: $(date +'%Y-%m-%d @ %H:%M:%S')"
echo "     Installation Log: $instlog"
_line

# We are expecting 1 or no parameters here.
if [[ $INSTALL_MODE = 1 ]]; then
	_note "Running installation mode!\n\n"
	imode="installation"
	swarg="-v"; install=0
else
	_note "Running in preview mode.\n\n"
	imode="preview"
fi

###########
# M A I N #
###########

_define_SourceDepot

#=====================================================================================#
int j
int HighestTestNr
set -A ActionTest			# build an array
for j in  $(hpuxseq 1 25)		# increase 25 if more tests are required
do
	# Action Lines - what are we gonna test? We start with comment lines...
	# we need to add a \ to escape the #
	ActionTest[$j]="\# Test $j : "
done
#=====================================================================================#

HighestTestNr=1		# we start with 1 not 0
# Test - OS Supported - only ment for HP-UX 11.11, 11.23 and 11.31
OS_supported $HighestTestNr "HP-UX ${OSver} supported"
HighestTestNr=$((HighestTestNr + 1))

# Test - Examine the patch level (if kernel patches need to be applied we stop)
Patch_Level $HighestTestNr "Patch Level"
HighestTestNr=$((HighestTestNr + 1))

# Test - corrupt filesets present (must be resolved before we can continue)
Corrupt_Filesets $HighestTestNr "Corrupt filesets found"
HighestTestNr=$((HighestTestNr + 1))

# Test - is $sourceDepo readable with swlist?
BaseDepo_os_available $HighestTestNr "Software Depot is available"
HighestTestNr=$((HighestTestNr + 1))

# Test - ISEEPlatform found?
$SWLIST | grep ISEEPlatform > $TMPFILE
_check_ISEEPlatform $HighestTestNr "ISEEPlatform"
HighestTestNr=$((HighestTestNr + 1))

# Test - unsupported SFM version found?
_check_old_SFM $HighestTestNr "Unsupported System Fault Mgt. \(SFM\) found"
HighestTestNr=$((HighestTestNr + 1))

# Test - unsupported ProviderSvcsCore found?
#_check_old_ProviderSvcsCore $HighestTestNr "Unsupported ProviderSvcsCore found"
#HighestTestNr=$((HighestTestNr + 1))

# Test - check OpenSSL version
$SWLIST [Oo]pen[Ss][Ss][Ll] > $TMPFILE
_check_openssl $HighestTestNr "OpenSSL"
HighestTestNr=$((HighestTestNr + 1))

# Test - check WBEMServices
_check_wbem $HighestTestNr "WBEMservices"
HighestTestNr=$((HighestTestNr + 1))

# Test - check STM and OnlineDiag
_check_onlinediag $HighestTestNr "OnlineDiag"
HighestTestNr=$((HighestTestNr + 1))

# test - stop SMH daemons
_stop_hpsmh $HighestTestNr "Stop System Mgmt Homepage"
HighestTestNr=$((HighestTestNr + 1))

# Test - apache version 2.0 check
_check_apache20 $HighestTestNr  "Apache v2.0"
HighestTestNr=$((HighestTestNr + 1))

# Test - apache version 2.2 check
_check_apache22 $HighestTestNr  "Apache v2.2"
HighestTestNr=$((HighestTestNr + 1))

# Test - check SMH
$SWLIST SysMgmtWeb > $TMPFILE 2>&1
_check_sysmgmtweb $HighestTestNr "SysMgmtWeb"
HighestTestNr=$((HighestTestNr + 1))

# Test - start SMH daemons again
_start_hpsmh $HighestTestNr "Start System Mgmt Homepage"
HighestTestNr=$((HighestTestNr + 1))

# Test - RSP patches required?
_check_rsp_patches $HighestTestNr "HP SIM/IRSA Patches"
HighestTestNr=$((HighestTestNr + 1))

# Test - check ProviderSvcsCore
#_check_ProviderSvcsCore $HighestTestNr "ProviderSvcsCore"
#HighestTestNr=$((HighestTestNr + 1))

# Test - check SFM
_check_sfm $HighestTestNr "System Fault Mgt"
HighestTestNr=$((HighestTestNr + 1))

# Test - check WBEMMgmtBundle (only 11.31)
_check_WBEMMgmtBundle $HighestTestNr "WBEMMgmtBundle"
HighestTestNr=$((HighestTestNr + 1))

# Test - install Remote Support Advanced Configuration Collector
_install_rs_acc $HighestTestNr "Remote Support Adv Conf Collector"
HighestTestNr=$((HighestTestNr + 1))

# Test - nParProvder install or update
_check_nParProvider $HighestTestNr "nParProvider"
HighestTestNr=$((HighestTestNr + 1))

# Test - vParProvder install or update
_check_vParProvider $HighestTestNr "vParProvider"
HighestTestNr=$((HighestTestNr + 1))

# Test - WBEMextras install or update required?
_check_WBEMextras $HighestTestNr "WBEMextras"
HighestTestNr=$((HighestTestNr + 1))

# Test - software configure all CIM providers
_swconfig_CIM_providers $HighestTestNr "Configure the CIM Providers"

#####################################################################
# Here we write our install script
{
echo "#!/usr/bin/ksh"
echo "{"
echo "######### Action Script for RSP Readiness
######### for system $HOSTNAME"
echo "######### status of `date`"
echo "## all actions run in \"${imode}\" mode!!"
for j in  $(hpuxseq 1 $HighestTestNr)
do
	echo ${ActionTest[$j]}
done
echo "} > $dlog/`basename ${ISCRIPT%???}`-install.scriptlog 2>&1"
} > $ISCRIPT && chmod 755 $ISCRIPT
# END of software prerequisites # # END of install script #

## start of verification/configuration process ##
# Here we start building our config script
{
echo "#!/usr/bin/ksh"
echo "{"
echo "######### Config Script for RSP Readiness
######### for system $HOSTNAME"
echo "######### created on `date`"
echo "export PATH=$PATH:/opt/wbem/bin:/opt/wbem/sbin"
echo "# swconfig EMS-Core - need to find the latest release to configure (move from install to here)"
# EMS-Core release nr
echo "r=\`swlist -l product | grep -i EMS-core | tail -1 | awk '{print \$2}'\`"
echo "swconfig -x autoselect_dependencies=false -x reconfigure=true -x mount_all_filesystems=false EMS-Core,r=\$r"
echo "echo"
echo "# List of active CIM Providers"
echo "echo \# List of active CIM Providers"
echo "cimprovider -l -s"
echo "echo"
echo "# Check Event Monitoring"
echo "echo \# Check Event Monitoring"
echo "echo q | /etc/opt/resmon/lbin/monconfig | grep -E 'EMS|STM'"
case ${OSver} in
	"B.11.11" ) echo "# Hardware monitors always use EMS"
		echo "echo \# Hardware monitors always use EMS"
		;;
	*) 	echo "# Hardware monitors (EMS or SFM)"
		echo "echo \# Hardware monitors \(EMS or SFM\)"
		echo "echo /opt/sfm/bin/sfmconfig -w -q"
		echo "/opt/sfm/bin/sfmconfig -w -q"
		echo "# Switch EMS monitoring to SFM (for 11.23 and 11.31)"
		echo "echo \# Switch EMS monitoring to SFM \(for 11.23 and 11.31\)"
		echo "echo /opt/sfm/bin/sfmconfig -w -s"
		echo "/opt/sfm/bin/sfmconfig -w -s"
		;;
esac
echo "echo"
echo "# check special wbem account (${WbemUser}) for monitoring with HP SIM"
echo "# grep ^${WbemUser} /etc/passwd"
echo "echo \# grep ^${WbemUser} /etc/passwd"
echo "grep \"^${WbemUser}\" /etc/passwd 2>&1"
echo "[ \$? -ne 0 ] && {"
	echo "	# Account ${WbemUser} does not exist - creating one"
	echo "	/usr/sbin/useradd -g users -G ${HpsmhAdminGroup} ${WbemUser}"
	echo "	/usr/sam/lbin/usermod.sam -F -p ${ENCPW} ${WbemUser}"
	echo "	/usr/lbin/modprpw -m exptm=0,lftm=0 ${WbemUser}"
	echo "	/usr/lbin/modprpw -v ${WbemUser}"
echo "	}"
echo "echo"
echo "# Print current CIM configuration"
echo "echo \# Print current CIM configuration"
echo "cimconfig -l -p"
echo "cimconfig -s enableSubscriptionsForNonprivilegedUsers=true -p"
echo "cimconfig -s enableNamespaceAuthorization=true -p"
echo "echo"
echo "# Stop cimserver"
echo "echo \# Stop cimserver"
echo "cimserver -s"
echo "echo \# Add secondary ${HpsmhAdminGroup} group to the ${WbemUser} account"
echo "/usr/sbin/usermod -G ${HpsmhAdminGroup} ${WbemUser}"
echo "echo"
echo "# Start cimserver"
echo "echo \# Start cimserver"
echo "cimserver"
echo "echo"
echo "# Check cimconfig"
echo "echo \# Check cimconfig"
echo "cimconfig -l -c"
echo "echo"
echo "# Add the needed CIM authorizations"
echo "echo \# Add the needed CIM authorizations"
echo "cimauth -l | grep ${WbemUser} | grep -q \"root/cimv2\" || cimauth -a -u ${WbemUser} -n root/cimv2 -R -W"
echo "cimauth -l | grep ${WbemUser} | grep -q \"root/PG_InterOp\" || cimauth -a -u ${WbemUser} -n root/PG_InterOp -R -W"
echo "cimauth -l | grep ${WbemUser} | grep -q \"root/PG_Internal\" || cimauth -a -u ${WbemUser} -n root/PG_Internal -R -W"
echo "cimauth -l | grep ${WbemUser} | grep -q \"root/cimv2/npar\" || cimauth -a -u ${WbemUser} -n root/cimv2/npar -R -W"
echo "cimauth -l | grep ${WbemUser} | grep -q \"root/cimv2/vpar\" || cimauth -a -u ${WbemUser} -n root/cimv2/vpar -R -W"
echo "cimauth -l | grep ${WbemUser} | grep -q \"root/cimv2/hpvm\" || cimauth -a -u ${WbemUser} -n root/cimv2/hpvm -R -W"
echo "# List the CIM authorizations"
echo "echo \# List the CIM authorizations"
echo "cimauth -l"
echo "echo"
echo "ls -l /var/opt/wbem/repository"
echo "# Check if SysFaultMgt processes are running:"
echo "echo \# Check if SysFaultMgt processes are running:"
echo "ps -ef | grep sfmdb | grep -v grep"
echo "echo"
echo "# Set System Management Homepage to start on boot and add ${HpsmhAdminGroup} group to authorized users:"
echo "echo \# Set System Management Homepage to start on boot and add ${HpsmhAdminGroup} group to authorized users:"
echo "/opt/hpsmh/lbin/hpsmh stop"
echo "cat >/opt/hpsmh/conf.common/smhpd.xml <<EOF"
echo "<?xml version=\"1.0\" encoding=\"UTF-8\"?>"
echo "<system-management-homepage>"
echo "<admin-group>${HpsmhAdminGroup}</admin-group>"
echo "<operator-group></operator-group>"
echo "<user-group></user-group>"
echo "<allow-default-os-admin>True</allow-default-os-admin>"
echo "<anonymous-access>False</anonymous-access>"
echo "<localaccess-enabled>False</localaccess-enabled>"
echo "<localaccess-type>Anonymous</localaccess-type>"
echo "<trustmode>TrustByCert</trustmode>"
echo "<xenamelist></xenamelist>"
echo "<ip-restricted-logins>False</ip-restricted-logins>"
echo "<ip-restricted-include></ip-restricted-include>"
echo "<ip-restricted-exclude></ip-restricted-exclude>"
echo "<ip-binding>False</ip-binding>"
echo "<ip-binding-list></ip-binding-list>"
echo "</system-management-homepage>"
echo "EOF"
echo "chmod 444 /opt/hpsmh/conf.common/smhpd.xml"
echo "/opt/hpsmh/bin/smhstartconfig -a off -b on"
echo "/opt/hpsmh/lbin/hpsmh start"
echo "/opt/hpsmh/bin/smhstartconfig"
echo ""
echo "# writing the ConfFile if needed"
echo "if [ ! -f $ConfFile ]; then"
echo "echo \# Writing a fresh $ConfFile file, which contains:"
echo "echo"
echo "[ ! -d $(dirname $ConfFile) ] && mkdir -p -m 755 $(dirname $ConfFile)"
echo "cat > $ConfFile <<EOF"
echo "#################################################"
echo "# ----- Configuration file HPSIM_irsa.conf -----#"
echo "#       Date: $(date '+%d %b %Y')                       #"
echo "#       Updated by: Gratien D'haese             #"
echo "#################################################"
echo "# Configuration file is read by (if available)"
echo "#       - HPSIM-Check-RSP-readiness.sh"
echo "#       - HPSIM-Upgrade-RSP.sh"
echo "#       - HPSIM-HealthCheck.sh"
echo "#       - restart_cim_sfm.sh"
echo "#################################################"
echo "# Default location of this file is:"
echo "#       /usr/local/etc/HPSIM_irsa.conf"
echo "# but may be overruled with the '-c' argument"
echo "#"
echo "#################################################"
echo "#       Variables available in this config file"
echo "#       have default settings in each script too"
echo "#       and may be overruled via command arguments"
echo "#       (don't worry if conf file is not found...)"
echo "#       Use the '-h' for help with each script"
echo "#################################################"
echo ""
echo "# The WBEM user used for HP SIM purposes"
echo "# WbemUser=wbem"
echo "WbemUser=${WbemUser}"
echo ""
echo "# The mail recipients to whom an output report will"
echo "# be send - default is none"
echo "# mailusr=\"root\""
echo "# mailusr=\"root,someuser@corporation.com\""
echo "mailusr=${mailusr}"
echo ""
echo "# The HP SIM server FQDN (no default for this one!)"
echo "# SimServer="HPSIM_FQDN""
echo "SimServer=${SimServer}"
echo ""
echo "# The maximum Test Delay in seconds for sending"
echo "# out a test event (only used by HPSIM-HealthCheck.sh)"
echo "# MaxTestDelay=0"
echo "MaxTestDelay=0"
echo ""
echo "# The logging directory where our log files will be kept"
echo "# dlog=/var/adm/install-logs    (default)"
echo "dlog=/var/adm/install-logs"
echo ""
echo "# The Ignite/UX or SD server where our HP-UX depots are kept"
echo "# IUXSERVER=FQDN"
echo "IUXSERVER=${IUXSERVER}"
echo ""
echo "# The location of the base HPSIM/IRSA depots"
echo "# baseDepo=/var/opt/ignite/depots/GLOBAL/rsp/pre-req"
echo "# without 11.11, 11.23 or 11.31 sub-depots names"
echo "baseDepo=${baseDepo}"
echo ""
echo "# The encrypted password of the WbemUser"
echo "# Variable only used by HPSIM-Check-RSP-readiness.sh script"
echo "# An easy way to produce such crypt password is with \"openssl passwd -crypt\", or"
echo "# HPSIM-Check-RSP-readiness.sh -p will prompt for a new password"
echo "# ENCPW=\"6u2CMymnCznQo\"         # default password is \"hpinvent\" (without the double quotes)"
echo "ENCPW=\"${ENCPW}\""
echo ""
echo "# The HP System Management Homepage Admin Group (hpsmh is default setting)"
echo "# The WbemUser will belong to this secondary group to allow access to HP SMH"
echo "HpsmhAdminGroup=\"${HpsmhAdminGroup}\""
echo "EOF"
echo "cat $ConfFile"
echo ""
echo "fi"
echo "} > $dlog/`basename ${CSCRIPT%???}`-config.scriptlog 2>&1"
} > $CSCRIPT && chmod 755 $CSCRIPT

# execute the ISCRIPT and CSCRIPT when the "-i" flag was set.
if [[ $INSTALL_MODE = 1 ]]; then
	# running the installation & config script (post-install ignite perhaps)
	_note "Running $ISCRIPT..."
	$ISCRIPT
	_note "Analyzing the install log file for errors"
	_check_install_log_for_errors

	_note "Running $CSCRIPT..."
	$CSCRIPT
	_note "Analyzing the config log file for errors"
	_check_config_log_for_errors
else
	_note "To view or run the installation script - check $ISCRIPT"
	_note "To view or run the config script - check $CSCRIPT"
fi

# print final EXITCODE result (counter of all ERRORS found - install and config part)
_line
if [ $EXITCODE -eq 0 ]; then
	_note "There were no errors detected."
elif [ $EXITCODE -eq 1 ]; then
	_note "There was 1 error detected (see details above or in the log files)"
else
	_note "There were several errors detected (see details above or in the log files)"
fi
_line
echo $EXITCODE > /tmp/EXITCODE.rsp
} 2>&1 | tee $instlog

EXITCODE=$(cat /tmp/EXITCODE.rsp 2>/dev/null)
# Final notification
if [[ $INSTALL_MODE = 1 ]]; then
	# install mode
	case $EXITCODE in
		0) msg="[SUCCESS] `basename $0` ran successfully in installation mode on $HOSTNAME" ;;
		1) msg="[WARNING] `basename $0` ran with warnings (or error) in installation mode on $HOSTNAME" ;;
		99) msg=$(cat /tmp/EXITCODE.txt 2>/dev/null)  ;;
		*) msg="[ERRORS] `basename $0` ran with errors in installation mode on $HOSTNAME" ;;
	esac
else
	# preview mode
	case $EXITCODE in
		99) msg=$(cat /tmp/EXITCODE.txt 2>/dev/null)  ;;
		*) msg="[SUCCESS] `basename $0` ran successfully in preview mode on $HOSTNAME" ;;
	esac
fi

_mail "$msg"

# Final cleanup
rm -f /tmp/EXITCODE.rsp /tmp/EXITCODE.txt
exit $EXITCODE

# ----------------------------------------------------------------------------
# $Log:  $
# $RCSfile:  $
# $Source:  $
# $State: Exp $
# ----------------------------------------------------------------------------

