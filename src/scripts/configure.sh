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
                IUXSERVER=hplabx1.dfdev.jnj.com
            elif (( $secdig == 56 || $secdig == 57 )); then
		# MOPS
		SimServer="itsusrasim5.jnj.com"
		IUXSERVER=itsblp02.jnj.com
            elif (( $secdig == 1 || $secdig <= 95 )); then
                # North America
                SimServer="itsusrasim5.jnj.com"
                IUXSERVER=itsblp02.jnj.com
            elif (( $secdig == 96 || $secdig <= 127 )); then
                # Latin America
                SimServer="itsusrasim5.jnj.com"
                IUXSERVER=itsblp02.jnj.com
            elif (( $secdig == 128 || $secdig <= 191 )); then
                # EU
                SimServer="itsbebesim03.jnj.com"
                IUXSERVER=hpx261.jnj.com
            elif (( $secdig == 192 || $secdig <= 223 )); then
                # ASPAC
                SimServer="itsbebesim03.jnj.com"
                IUXSERVER=hpx261.jnj.com
            else
                # Leftovers come to NA
                SimServer="itsusrasim5.jnj.com"
                IUXSERVER=itsblp02.jnj.com
            fi
	    ;;
        *)
	    /usr/bin/echo "       * NOTE: Could not determine network location.  Using defaults."
	    SimServer=itsusrasim5.jnj.com
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
#_region

if [[ ! -f /usr/newconfig/usr/local/etc/HPSIM_irsa.conf ]]
then
	/usr/bin/echo "       * Did not find the template /usr/newconfig/usr/local/etc/HPSIM_irsa.conf file"
	exit 1
fi

/usr/bin/sed -e 's/^SimServer=.*/SimServer='$SimServer'/' -e 's/^IUXSERVER=.*/IUXSERVER='$IUXSERVER'/' \
	< /usr/newconfig/usr/local/etc/HPSIM_irsa.conf >$CFGFILE
/sbin/chmod 640 $CFGFILE
/sbin/chown root:sys $CFGFILE
/usr/bin/echo "       * Created the $CFGFILE"
/usr/bin/echo "       * Using value: SimServer=$SimServer"
/usr/bin/echo "       * Using value: IUXSERVER=$IUXSERVER"

############################
#   Compare config files   #
############################
LATEST_BACKUP_COPY_CFGFILE="$(ls -1rt $CFGFILE.* 2>/dev/null | tail -1)"

[[ -z "$LATEST_BACKUP_COPY_CFGFILE" ]] && exit 0  # nothing to do

if (! /usr/bin/diff $CFGFILE $LATEST_BACKUP_COPY_CFGFILE); then
    /usr/bin/echo "       * WARNING: The configuration file $CFGFILE differs with old copy"
    /usr/bin/echo "       * WARNING: Please decide if the difference with $LATEST_BACKUP_COPY_CFGFILE is important or not"
fi
exit $exitval
