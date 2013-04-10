SHELL = /usr/bin/sh
product = WBEMextras
psf_file = ./WBEMextras.psf
depot_dir = /tmp/$(product).depot.dir

all: clean build

clean:
	@if [ `whoami` != "root" ]; then echo "Only root may remove packages"; exit 1; fi; \
	rm -rf $(depot_dir) ; \
	echo "Depot directory [$(depot_dir)] successfully removed"

help:
	@echo "==============================="
	@echo "Type \"make\" to build WBEMextras"
	@echo "==============================="

build:
	if [ `whoami` != "root" ]; then echo "Only root may build packages"; exit 1; fi; \
	/usr/sbin/swpackage -vv -s $(psf_file) -x layout_version=1.0 -d $(depot_dir) ; \
	num=`/usr/bin/grep 'number' $(psf_file) | awk '{print $$2}'` ; \
	depot_file=./$(product)_$$num.depot ; \
	/usr/sbin/swpackage -vv -d $$depot_file  -x target_type=tape -s $(depot_dir) \* ; \
	echo "File depot location is $$depot_file" ; \
	echo "Done."
