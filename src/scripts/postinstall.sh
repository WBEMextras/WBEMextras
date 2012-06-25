#!/bin/sh
# WBEMextras postinstall.sh

# keep a copy of previous active crontab file
cronfile=/var/tmp/cronfile.$(date +'%Y-%m-%d')
crontab -l > $cronfile
echo "       * current active crontab file saved as $cronfile"

# remove old redundant entries
egrep -v 'restart_sfm|restart_cim_sfm|SFMProviderModule' $cronfile  > $cronfile.new
# add new entry
echo "6,21,36,51 * * * * /usr/local/bin/restart_cim_sfm.sh  > /dev/null 2>&1" >> $cronfile.new

# activate the new crontab file
crontab $cronfile.new

# show the added line
echo "       * Added line to crontab:"
echo "         $(crontab -l | grep restart_cim_sfm)"

# cleanup
rm -f $cronfile.new
