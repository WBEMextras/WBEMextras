#!/bin/sh
# WBEMextras postremove.sh

# keep a copy of previous active crontab file
cronfile=/var/tmp/cronfile.$(date +'%Y-%m-%d')
crontab -l > $cronfile
echo "       * current active crontab file saved as $cronfile"

# remove /usr/local/bin/restart_cim_sfm.sh entry
grep -v 'restart_cim_sfm' $cronfile  > $cronfile.new

# activate the new crontab file
crontab $cronfile.new
