#!/sbin/sh
# WBEMextras configure.sh

########

    UTILS="/usr/lbin/sw/control_utils"
    if [[ ! -f $UTILS ]]
    then
        /usr/bin/echo "ERROR: Cannot find $UTILS"
        exit 1
    fi
    . $UTILS
    exitval=$SUCCESS                           # Anticipate success


################################################################################

function _region {
    secdig=$(/usr/bin/netstat -rn | /usr/bin/awk '/default/ && /UG/ { print $2 | "/usr/bin/tail -1" }' | /usr/bin/cut -d. -f2)
    case $secdig in
	+([0-9]))
            if (( $secdig == 0 )); then
                # Lab
                SimServer="itsusratdc03.dfdev.jnj.com"
                IUXSERVER=bl870ci2.dfdev.jnj.com
            elif (( $secdig == 56 || $secdig == 57 )); then
		# MOPS
		SimServer="itsusraw01231.jnj.com"
		IUXSERVER=itsblp02.jnj.com
            elif (( $secdig == 1 || $secdig <= 95 )); then
                # North America
                SimServer="itsusraw01231.jnj.com"
                IUXSERVER=itsblp02.jnj.com
            elif (( $secdig == 96 || $secdig <= 127 )); then
                # Latin America
                SimServer="itsusraw01231.jnj.com"
                IUXSERVER=itsblp02.jnj.com
            elif (( $secdig == 128 || $secdig <= 191 )); then
                # EU
                SimServer="itsbebew00331.jnj.com"
                IUXSERVER=hpx261.jnj.com
            elif (( $secdig == 192 || $secdig <= 223 )); then
                # ASPAC
                SimServer="ITSAPSYSIM01.jnj.com"
                IUXSERVER=hpx261.jnj.com
            else
                # Leftovers come to NA
                SimServer="itsusraw01231.jnj.com"
                IUXSERVER=itsblp02.jnj.com
            fi
	    ;;
        *)
	    /usr/bin/echo "       * NOTE: Could not determine network location.  Using defaults."
	    SimServer=itsusraw01231.jnj.com
	    IUXSERVER=itsblp02.jnj.com
	    ;;
    esac
}


######################################
####		M A I N 	  ####
######################################

### create a new /usr/local/etc/HPSIM_irsa.conf from the template conf file
## /usr/newconfig/usr/local/etc/HPSIM_irsa.conf according region
### advantage is that 'swverify' will not complain about changed files!!

CFGFILE="/usr/local/etc/HPSIM_irsa.conf"

# predefine the $SimServer and $IUXSERVER variables by hardcoding it or by function _region
_region

if [[ ! -f /usr/newconfig/usr/local/etc/HPSIM_irsa.conf ]]
then
	/usr/bin/echo "       * Did not find the template /usr/newconfig/usr/local/etc/HPSIM_irsa.conf file"
	exit 1
fi

# make sure when we upgrade WBEMextras that we do not overwrite the current cfgfile
if [[ ! -f "$CFGFILE" ]] ; then
    # fresh installation - $CFGFILE does not yet exist - create one
    count=0
    /usr/bin/sed -e 's/^SimServer\[0\]=.*/SimServer\[0\]='$SimServer'/' -e 's/^IUXSERVER=.*/IUXSERVER='$IUXSERVER'/' \
	< /usr/newconfig/usr/local/etc/HPSIM_irsa.conf > "$CFGFILE"
else
    # ok this is an upgrade - do an inplace modification
    LATEST_BACKUP_COPY_CFGFILE="$(/usr/bin/ls -1rt $CFGFILE.* 2>/dev/null | /usr/bin/tail -1)"  # preinstall script did this
    if [[ -z "$LATEST_BACKUP_COPY_CFGFILE" ]] ; then
	cp -p "$CFGFILE"  "$CFGFILE.$(date +'%Y-%m-%d')"  # make a copy (extention, e.g. 2014-10-28)
	LATEST_BACKUP_COPY_CFGFILE="$CFGFILE.$(date +'%Y-%m-%d')"
    fi
    # check if $CFGFILE defined SimServer as an array or not?
    /usr/bin/grep -q "^SimServer=" "$LATEST_BACKUP_COPY_CFGFILE"
    if [[ $? -eq 0 ]] ; then
        # old style (no array definition) - new cfgfile will use array definition
	count=0
	/usr/bin/sed -e 's/^SimServer=.*/SimServer\[0\]='$SimServer'/' -e 's/^IUXSERVER=.*/IUXSERVER='$IUXSERVER'/' \
	   < "$LATEST_BACKUP_COPY_CFGFILE" > "$CFGFILE"
    else
	# be careful we could have more definitions of SimServer[*]
	/usr/bin/grep ^SimServer "$LATEST_BACKUP_COPY_CFGFILE" > /tmp/SimServer.list.$$
	count=$( /usr/bin/wc -l  /tmp/SimServer.list.$$ | /usr/bin/awk '{print $1}' )   # amount of lines with simservers
	/usr/bin/grep -q "$SimServer" /tmp/SimServer.list.$$
	if [[ $? -eq 0 ]]; then
            # SimServer is already in the list; do nothing
	    count=$(( count - 1 ))   # need to decrement as array element start with 0
	else
	   # we know that $SimServer is not part of the current list; $count is already correct
	   /usr/bin/echo "SimServer[$count]=$SimServer" >> "$CFGFILE"
	   /usr/bin/rm -f /tmp/SimServer.list.$$
	fi
    fi
fi

/sbin/chmod 640 $CFGFILE
/sbin/chown root:sys $CFGFILE
/usr/bin/echo "       * Created the $CFGFILE"
/usr/bin/echo "       * Using value: SimServer[$count]=$SimServer"
/usr/bin/echo "       * Using value: IUXSERVER=$IUXSERVER"

############################
#   Compare config files   #
############################
LATEST_BACKUP_COPY_CFGFILE="$(/usr/bin/ls -1rt $CFGFILE.* 2>/dev/null | /usr/bin/tail -1)"

[[ -z "$LATEST_BACKUP_COPY_CFGFILE" ]] && exit 0  # nothing to do

if (! /usr/bin/diff $CFGFILE $LATEST_BACKUP_COPY_CFGFILE); then
    /usr/bin/echo "       * WARNING: The configuration file $CFGFILE differs with old copy"
    /usr/bin/echo "       * WARNING: Please decide if the difference with $LATEST_BACKUP_COPY_CFGFILE is important or not"
fi
exit $exitval
