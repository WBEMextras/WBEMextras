################################################################################
# Version Info : @(#)make_hpux_depot.sh	1.1	04/Apr/2012
################################################################################
if [ -f ./WBEMextras.psf ]; then
	number="_$(grep number ./WBEMextras.psf | awk '{print $2}')"
else
	number=""
fi
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

echo "       * Creating new portable file depot WBEMextras${number}.depot"
/usr/sbin/swpackage -v -d ./WBEMextras${number}.depot -x target_type=tape \
	-x media_capacity=4000 -s ./WBEMextras.dirdepot WBEMextras

echo "       * Done."
