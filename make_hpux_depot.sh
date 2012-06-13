################################################################################
# Version Info : @(#)make_hpux_depot.sh	1.1	04/Apr/2012
################################################################################
if [ -d ./WBEMextras.dirdepot.prev ]; then
	rm -rf ./WBEMextras.dirdepot.prev
fi
if [ -d ./WBEMextras.dirdepot ]; then
	echo "       * Move WBEMextras.dirdepot to WBEMextras.dirdepot.prev"
	mv ./WBEMextras.dirdepot ./WBEMextras.dirdepot.prev
fi

echo "       * Creating new directory depot WBEMextras.dirdepot"
/usr/sbin/swpackage -vv -s ./WBEMextras.psf -x layout_version=1.0 \
	-d ./WBEMextras.dirdepot

echo "       * Creating new file depot WBEMextras.depot"
/usr/sbin/swpackage -v -d ./WBEMextras.depot -x target_type=tape \
	-x media_capacity=4000 -s ./WBEMextras.dirdepot WBEMextras

echo "       * Done."
