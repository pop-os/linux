# We don't want make removing intermediary stamps
.SECONDARY :

# Per-flavor variables (evaluated at runtime)
abi_dir = $(builddir)/abi-$*
build_dir = $(builddir)/build-$*

# TODO this is probably wrong, and should be using $(DEB_HOST_MULTIARCH)
shlibdeps_opts = $(if $(CROSS_COMPILE),-- -l$(CROSS_COMPILE:%-=/usr/%)/lib)

debian/scripts/fix-filenames: debian/scripts/fix-filenames.c
	$(HOSTCC) $^ -o $@

$(stampdir)/stamp-prepare-%: debian/scripts/fix-filenames
	@echo Debug: $@
	install -d $(build_dir)
	touch $(build_dir)/ubuntu-build
	python3 debian/scripts/misc/annotations --export --arch $(arch) --flavour $* > $(build_dir)/.config
	sed -i 's/.*CONFIG_VERSION_SIGNATURE.*/CONFIG_VERSION_SIGNATURE="Ubuntu $(DEB_VERSION_UPSTREAM)-$(DEB_REVISION)-$* $(raw_kernelversion)"/' $(build_dir)/.config
	find $(build_dir) -name "*.ko" | xargs rm -f
	$(kmake) O=$(build_dir) $(conc_level) rustavailable || true
	$(kmake) O=$(build_dir) $(conc_level) olddefconfig
ifneq ($(do_skip_checks),true)
	python3 debian/scripts/misc/annotations -f $(CURDIR)/$(DEBIAN)/config/annotations \
		--arch $(arch) --flavour $* --check $(build_dir)/.config
endif
	$(stamp)

# Used by developers as a shortcut to prepare a tree for compilation.
prepare-%: $(stampdir)/stamp-prepare-%
	@echo Debug: $@
# Used by developers to allow efficient pre-building without fakeroot.
build-%: $(stampdir)/stamp-install-%
	@echo Debug: $@

# Do the actual build, including image and modules
$(stampdir)/stamp-build-%: bldimg = $(call custom_override,build_image,$*)
$(stampdir)/stamp-build-%: $(stampdir)/stamp-build-perarch $(stampdir)/stamp-prepare-%
	@echo Debug: $@ build_image $(build_image) bldimg $(bldimg)
	$(kmake) O=$(build_dir) $(conc_level) $(bldimg) modules $(if $(filter true,$(do_dtbs)),dtbs)

ifeq ($(do_dbgsym_package),true)
	# The target scripts_gdb is part of "all", so we need to call it manually
	if grep -q CONFIG_GDB_SCRIPTS=y $(build_dir)/.config; then \
		$(kmake) O=$(build_dir) $(conc_level) scripts_gdb ; \
	fi
endif

ifeq ($(do_linux_tools),true)
 ifeq ($(do_tools_bpftool),true)
  ifeq ($(do_tools_bpftool_stub),true)
	echo '#error "Kernel does not support CONFIG_DEBUG_INFO_BTF"' > $(build_dir)/vmlinux.h
  else
	$(builddirpa)/tools/bpf/bpftool/bpftool btf dump file $(build_dir)/vmlinux format c > $(build_dir)/vmlinux.h
  endif
 endif
endif

	# Collect the list of kernel source files used for this build. Need to do this early
	# before modules are stripped. Fail if the resulting file is empty.
	find $(build_dir) \( -name vmlinux -o -name \*.ko \) -exec dwarfdump -i {} \; | \
		grep -E 'DW_AT_(call|decl)_file' | sed -n 's|.*\s/|/|p' | sort -u > \
		$(build_dir)/sources.list
	test -s $(build_dir)/sources.list

	$(stamp)

define build_dkms_sign =
	$(shell set -x; if grep -q CONFIG_MODULE_SIG=y $(1)/.config; then
			echo $(1)/scripts/sign-file $(MODHASHALGO) $(MODSECKEY) $(MODPUBKEY);
		else
			echo "-";
		fi
	)
endef
define build_dkms =
	rc=0; unset MAKEFLAGS; ARCH=$(build_arch) CROSS_COMPILE=$(CROSS_COMPILE) $(SHELL) debian/scripts/dkms-build $(dkms_dir) $(abi_release)-$* '$(call build_dkms_sign,$(build_dir))' $(1) $(2) $(3) $(4) $(5) || rc=$$?; if [ "$$rc" = "9" -o "$$rc" = "77" ]; then echo do_$(4)_$*=false >> $(builddir)/skipped-dkms.mk; rc=0; fi; if [ "$$rc" != "0" ]; then exit $$rc; fi
endef

define install_control =
	for which in $(3);							\
	do									\
		template="debian/templates/$(2).$$which.in";			\
		script="debian/$(1).$$which";					\
		sed -e 's/@abiname@/$(abi_release)/g'				\
		    -e 's/@localversion@/-$*/g'					\
		    -e 's/@image-stem@/$(instfile)/g'				\
			<"$$template" >"$$script";				\
	done
endef

# Ensure the directory prefix is exactly 140 characters long so pathnames are the
# exact same length in any binary files produced by the builds.  These will be
# commonised later.
dkms_20d=....................
dkms_140d=$(dkms_20d)$(dkms_20d)$(dkms_20d)$(dkms_20d)$(dkms_20d)$(dkms_20d)$(dkms_20d)
dkms_140c=$(shell echo '$(dkms_140d)' | sed -e 's/\./_/g')
define dkms_dir_prefix =
$(shell echo $(1)/$(dkms_140c) | \
	sed -e 's/\($(dkms_140d)\).*/\1/' -e 's/^\(.*\)....$$/\1dkms/')
endef

# Install the finished build
$(stampdir)/stamp-install-%: pkgdir_bin = $(CURDIR)/debian/$(bin_pkg_name)-$*
$(stampdir)/stamp-install-%: pkgdir = $(CURDIR)/debian/$(mods_pkg_name)-$*
$(stampdir)/stamp-install-%: pkgdir_ex = $(CURDIR)/debian/$(mods_extra_pkg_name)-$*
$(stampdir)/stamp-install-%: pkgdir_bldinfo = $(CURDIR)/debian/$(bldinfo_pkg_name)-$*
$(stampdir)/stamp-install-%: bindoc = $(pkgdir)/usr/share/doc/$(bin_pkg_name)-$*
$(stampdir)/stamp-install-%: dbgpkgdir = $(CURDIR)/debian/$(bin_pkg_name)-$*-dbgsym
$(stampdir)/stamp-install-%: signingv = $(CURDIR)/debian/$(bin_pkg_name)-signing/$(DEB_VERSION_UPSTREAM)-$(DEB_REVISION)
$(stampdir)/stamp-install-%: toolspkgdir = $(CURDIR)/debian/$(tools_flavour_pkg_name)-$*
$(stampdir)/stamp-install-%: cloudpkgdir = $(CURDIR)/debian/$(cloud_flavour_pkg_name)-$*
$(stampdir)/stamp-install-%: bpfdevpkgdir = $(CURDIR)/debian/linux-bpf-dev
$(stampdir)/stamp-install-%: basepkg = $(hdrs_pkg_name)
$(stampdir)/stamp-install-%: baserustpkg = $(rust_pkg_name)
$(stampdir)/stamp-install-%: indeppkg = $(indep_hdrs_pkg_name)
$(stampdir)/stamp-install-%: kernfile = $(call custom_override,kernel_file,$*)
$(stampdir)/stamp-install-%: instfile = $(call custom_override,install_file,$*)
$(stampdir)/stamp-install-%: hdrdir = $(CURDIR)/debian/$(basepkg)-$*/usr/src/$(basepkg)-$*
$(stampdir)/stamp-install-%: rustdir = $(CURDIR)/debian/$(baserustpkg)-$*/usr/src/$(baserustpkg)-$*
$(stampdir)/stamp-install-%: MODHASHALGO=sha512
$(stampdir)/stamp-install-%: MODSECKEY=$(build_dir)/certs/signing_key.pem
$(stampdir)/stamp-install-%: MODPUBKEY=$(build_dir)/certs/signing_key.x509
$(stampdir)/stamp-install-%: dkms_dir=$(call dkms_dir_prefix,$(build_dir))
$(foreach _m,$(all_dkms_modules), \
  $(eval $$(stampdir)/stamp-install-%: enable_$(_m) = $$(filter true,$$(call custom_override,do_$(_m),$$*))) \
  $(eval $$(stampdir)/stamp-install-%: dkms_$(_m)_pkgdir = $$(CURDIR)/debian/$(dkms_$(_m)_pkg_name)-$$*) \
)
$(stampdir)/stamp-install-%: dbgpkgdir_dkms = $(if $(filter true,$(do_dbgsym_package)),$(dbgpkgdir)/usr/lib/debug/lib/modules/$(abi_release)-$*/kernel,"")
$(stampdir)/stamp-install-%: $(stampdir)/stamp-install-headers $(stampdir)/stamp-build-%
	@echo Debug: $@ kernel_file $(kernel_file) kernfile $(kernfile) install_file $(install_file) instfile $(instfile)
	dh_testdir
	dh_prep -p$(bin_pkg_name)-$*
	dh_prep -p$(mods_pkg_name)-$*
	dh_prep -p$(hdrs_pkg_name)-$*
ifeq ($(do_lib_rust),true)
	dh_prep -p$(rust_pkg_name)-$*
endif
	$(foreach _m,$(all_standalone_dkms_modules), \
	  $(if $(enable_$(_m)),dh_prep -p$(dkms_$(_m)_pkg_name)-$*;)\
	)
ifeq ($(do_dbgsym_package),true)
	dh_prep -p$(bin_pkg_name)-$*-dbgsym
endif
ifeq ($(do_extras_package),true)
	dh_prep -p$(mods_extra_pkg_name)-$*
endif
ifeq ($(do_linux_tools),true)
 ifeq ($(do_tools_bpftool),true)
  ifneq ($(filter linux-bpf-dev,$(packages_enabled)),)
	# Do this only for the primary (first) flavor
	# linux-bpf-dev is broken: It provides vmlinux.h which is a flavored header file!
	if [ $* = $(firstword $(flavours)) ] ; then \
		dh_prep -plinux-bpf-dev ; \
	fi
  endif
 endif
endif

	# The main image
	install -m600 -D $(build_dir)/$(kernfile) \
		$(pkgdir_bin)/boot/$(instfile)-$(abi_release)-$*
	install -d $(pkgdir)/boot
	install -m644 $(build_dir)/.config \
		$(pkgdir)/boot/config-$(abi_release)-$*
	install -m600 $(build_dir)/System.map \
		$(pkgdir)/boot/System.map-$(abi_release)-$*

ifeq ($(do_dtbs),true)
	$(kmake) O=$(build_dir) $(conc_level) dtbs_install \
		INSTALL_DTBS_PATH=$(pkgdir)/lib/firmware/$(abi_release)-$*/device-tree
endif

ifeq ($(no_dumpfile),)
	makedumpfile -g $(pkgdir)/boot/vmcoreinfo-$(abi_release)-$* \
		-x $(build_dir)/vmlinux
	chmod 0600 $(pkgdir)/boot/vmcoreinfo-$(abi_release)-$*
endif

	$(kmake) O=$(build_dir) $(conc_level) modules_install $(vdso) \
		INSTALL_MOD_STRIP=1 INSTALL_MOD_PATH=$(pkgdir)

	#
	# Build module blacklists:
	#  - blacklist all watchdog drivers (LP:1432837)
	#
	install -d $(pkgdir)/lib/modprobe.d
	echo "# Kernel supplied blacklist for $(DEB_SOURCE) $(abi_release)-$* $(arch)" \
		>$(pkgdir)/lib/modprobe.d/blacklist_$(DEB_SOURCE)_$(abi_release)-$*.conf
	for conf in $(arch)-$* $(arch) common.conf; do \
		if [ -f $(DEBIAN)/modprobe.d/$$conf ]; then \
			echo "# modprobe.d/$$conf"; \
			cat $(DEBIAN)/modprobe.d/$$conf; \
		fi; \
	done >>$(pkgdir)/lib/modprobe.d/blacklist_$(DEB_SOURCE)_$(abi_release)-$*.conf
	echo "# Autogenerated watchdog blacklist" \
		>>$(pkgdir)/lib/modprobe.d/blacklist_$(DEB_SOURCE)_$(abi_release)-$*.conf
	ls -1 $(pkgdir)/lib/modules/$(abi_release)-$*/kernel/drivers/watchdog/ | \
		grep -v '^bcm2835_wdt$$' | \
		sed -e 's/^/blacklist /' -e 's/.ko$$//' | \
		sort -u \
		>>$(pkgdir)/lib/modprobe.d/blacklist_$(DEB_SOURCE)_$(abi_release)-$*.conf

ifeq ($(do_extras_package),true)
	#
	# Remove all modules not in the inclusion list.
	#
	if [ -f $(DEBIAN)/control.d/$*.inclusion-list ] ; then \
		/sbin/depmod -v -b $(pkgdir) $(abi_release)-$* | \
			sed -e "s@$(pkgdir)/lib/modules/$(abi_release)-$*/kernel/@@g" | \
			awk '{ print $$1 " " $$NF}' >$(build_dir)/module-inclusion.depmap; \
		mkdir -p $(pkgdir_ex)/lib/modules/$(abi_release)-$*; \
		mv $(pkgdir)/lib/modules/$(abi_release)-$*/kernel \
			$(pkgdir_ex)/lib/modules/$(abi_release)-$*/kernel; \
		$(SHELL) debian/scripts/module-inclusion --master \
			$(pkgdir_ex)/lib/modules/$(abi_release)-$*/kernel \
			$(pkgdir)/lib/modules/$(abi_release)-$*/kernel \
			$(DEBIAN)/control.d/$*.inclusion-list \
			$(build_dir)/module-inclusion.depmap 2>&1 | \
				tee $*.inclusion-list.log; \
		/sbin/depmod -b $(pkgdir) -ea -F $(pkgdir)/boot/System.map-$(abi_release)-$* \
			$(abi_release)-$* 2>&1 |tee $*.depmod.log; \
		if [ `grep -c 'unknown symbol' $*.depmod.log` -gt 0 ]; then \
			echo "EE: Unresolved module dependencies in base package!"; \
			exit 1; \
		fi \
	fi
endif

ifeq ($(no_dumpfile),)
	makedumpfile -g $(pkgdir)/boot/vmcoreinfo-$(abi_release)-$* \
		-x $(build_dir)/vmlinux
	chmod 0600 $(pkgdir)/boot/vmcoreinfo-$(abi_release)-$*
endif
	rm -f $(pkgdir)/lib/modules/$(abi_release)-$*/build
	rm -f $(pkgdir)/lib/modules/$(abi_release)-$*/source

	# Some initramfs-tools specific modules
	install -d $(pkgdir)/lib/modules/$(abi_release)-$*/initrd
	if [ -f $(pkgdir)/lib/modules/$(abi_release)-$*/kernel/drivers/video/vesafb.ko ]; then\
	  $(LN) $(pkgdir)/lib/modules/$(abi_release)-$*/kernel/drivers/video/vesafb.ko \
		$(pkgdir)/lib/modules/$(abi_release)-$*/initrd/; \
	fi

	echo "interest linux-update-$(abi_release)-$*" >"debian/$(bin_pkg_name)-$*.triggers"
	install -d $(pkgdir_bin)/usr/lib/linux/triggers
	$(call install_control,$(bin_pkg_name)-$*,image,postinst postrm preinst prerm)
	install -d $(pkgdir)/usr/lib/linux/triggers
	$(call install_control,$(mods_pkg_name)-$*,extra,postinst postrm)
ifeq ($(do_extras_package),true)
	# Install the postinit/postrm scripts in the extras package.
	if [ -f $(DEBIAN)/control.d/$*.inclusion-list ] ; then	\
		install -d $(pkgdir_ex)/usr/lib/linux/triggers; \
		$(call install_control,$(mods_extra_pkg_name)-$*,extra,postinst postrm); \
	fi
endif
	$(foreach _m,$(all_standalone_dkms_modules), \
	  $(if $(enable_$(_m)), \
	    install -d $(dkms_$(_m)_pkgdir)/usr/lib/linux/triggers; \
	    $(call install_control,$(dkms_$(_m)_pkg_name)-$*,extra,postinst postrm); \
	  ) \
	)

ifeq ($(do_dbgsym_package),true)
	# Debug image is simple
	install -m644 -D $(build_dir)/vmlinux \
		$(dbgpkgdir)/usr/lib/debug/boot/vmlinux-$(abi_release)-$*
	if [ -d $(build_dir)/scripts/gdb/linux ]; then \
		install -m644 -D $(build_dir)/vmlinux-gdb.py \
			$(dbgpkgdir)/usr/share/gdb/auto-load/boot/vmlinux-$(abi_release)-$*/vmlinuz-$(abi_release)-$*-gdb.py; \
	fi
	$(kmake) O=$(build_dir) modules_install $(vdso) \
		INSTALL_MOD_PATH=$(dbgpkgdir)/usr/lib/debug
	# Add .gnu_debuglink sections only after all/DKMS modules are built.
	rm -f $(dbgpkgdir)/usr/lib/debug/lib/modules/$(abi_release)-$*/build
	rm -f $(dbgpkgdir)/usr/lib/debug/lib/modules/$(abi_release)-$*/source
	rm -f $(dbgpkgdir)/usr/lib/debug/lib/modules/$(abi_release)-$*/modules.*
	rm -fr $(dbgpkgdir)/usr/lib/debug/lib/firmware
endif

	# The flavour specific headers image
	# TODO: Would be nice if we didn't have to dupe the original builddir
	install -d -m755 $(hdrdir)
	cp $(build_dir)/.config $(hdrdir)
	chmod 644 $(hdrdir)/.config
	$(kmake) O=$(hdrdir) -j1 syncconfig prepare scripts
	# Makefile may need per-arch-flavour CC settings, which are
	# normally set via $(kmake) during build
	rm -f $(hdrdir)/Makefile
	cp -a $(indep_hdrdir)/Makefile $(hdrdir)/Makefile
	sed -i 's|\(^HOSTCC	= \)gcc$$|\1$(gcc)|' $(hdrdir)/Makefile
	sed -i 's|\(^CC		= $$(CROSS_COMPILE)\)gcc$$|\1$(gcc)|' $(hdrdir)/Makefile
	# Quick check for successful substitutions
	grep '^HOSTCC	.*$(gcc)$$' $(hdrdir)/Makefile
	grep '^CC	.*$(gcc)$$' $(hdrdir)/Makefile
	rm -rf $(hdrdir)/include2 $(hdrdir)/source
	# Copy over the compilation version.
	cp "$(build_dir)/include/generated/compile.h" \
		"$(hdrdir)/include/generated/compile.h"
	# Add UTS_UBUNTU_RELEASE_ABI since UTS_RELEASE is difficult to parse.
	echo "#define UTS_UBUNTU_RELEASE_ABI $(abinum)" >> $(hdrdir)/include/generated/utsrelease.h
	# powerpc kernel arch seems to need some .o files for external module linking. Add them in.
ifeq ($(build_arch),powerpc)
	mkdir -p $(hdrdir)/arch/powerpc/lib
	cp $(build_dir)/arch/powerpc/lib/*.o $(hdrdir)/arch/powerpc/lib
endif
ifeq ($(build_arch),s390)
	if [ -n "$$(find $(build_dir)/arch/s390/lib/expoline -maxdepth 1 -name '*.o' -print -quit)" ]; then \
		mkdir -p $(hdrdir)/arch/s390/lib/expoline/; \
		cp $(build_dir)/arch/s390/lib/expoline/*.o $(hdrdir)/arch/s390/lib/expoline/; \
	fi
endif
	# Copy over scripts/module.lds for building external modules
	cp $(build_dir)/scripts/module.lds $(hdrdir)/scripts
	# Script to symlink everything up
	$(SHELL) debian/scripts/link-headers "$(hdrdir)" "$(indeppkg)" "$*"
	# The build symlink
	install -d debian/$(basepkg)-$*/lib/modules/$(abi_release)-$*
	$(LN) /usr/src/$(basepkg)-$* \
		debian/$(basepkg)-$*/lib/modules/$(abi_release)-$*/build
	# And finally the symvers
	install -m644 $(build_dir)/Module.symvers \
		$(hdrdir)/Module.symvers

	# Now the header scripts
	$(call install_control,$(hdrs_pkg_name)-$*,headers,postinst)

	# At the end of the package prep, run the module signature check
	debian/scripts/checks/module-signature-check "$*" "$(pkgdir)" "$(pkgdir_ex)" $(do_skip_checks)

	#
	# Remove files which are generated at installation by postinst,
	# except for modules.order and modules.builtin
	#
	# NOTE: need to keep this list in sync with postrm
	#
	mkdir $(pkgdir)/lib/modules/$(abi_release)-$*/_
	mv $(pkgdir)/lib/modules/$(abi_release)-$*/modules.order \
		$(pkgdir)/lib/modules/$(abi_release)-$*/_
	if [ -f $(pkgdir)/lib/modules/$(abi_release)-$*/modules.builtin ] ; then \
	    mv $(pkgdir)/lib/modules/$(abi_release)-$*/modules.builtin \
		$(pkgdir)/lib/modules/$(abi_release)-$*/_; \
	fi
	if [ -f $(pkgdir)/lib/modules/$(abi_release)-$*/modules.builtin.modinfo ] ; then \
	    mv $(pkgdir)/lib/modules/$(abi_release)-$*/modules.builtin.modinfo \
		$(pkgdir)/lib/modules/$(abi_release)-$*/_; \
	fi
	rm -f $(pkgdir)/lib/modules/$(abi_release)-$*/modules.*
	mv $(pkgdir)/lib/modules/$(abi_release)-$*/_/* \
		$(pkgdir)/lib/modules/$(abi_release)-$*
	rmdir $(pkgdir)/lib/modules/$(abi_release)-$*/_

ifeq ($(do_linux_tools),true)
	# Create the linux-tools tool link
	install -d $(toolspkgdir)/usr/lib/linux-tools
	$(LN) ../$(DEB_SOURCE)-tools-$(abi_release) $(toolspkgdir)/usr/lib/linux-tools/$(abi_release)-$*
 ifeq ($(do_tools_bpftool),true)
  ifneq ($(filter linux-bpf-dev,$(packages_enabled)),)
	# Do this only for the primary (first) flavor
	# linux-bpf-dev is broken: It provides vmlinux.h which is a flavored header file!
	if [ $* = $(firstword $(flavours)) ] ; then \
		install -d -m755 $(bpfdevpkgdir)/usr/include/$(DEB_HOST_MULTIARCH)/linux/ ; \
		install -m644 $(build_dir)/vmlinux.h \
			 $(bpfdevpkgdir)/usr/include/$(DEB_HOST_MULTIARCH)/linux/ ; \
	fi
  endif
 endif
endif

ifeq ($(do_cloud_tools),true)
 ifeq ($(do_tools_hyperv),true)
	# Create the linux-hyperv tool link
	install -d $(cloudpkgdir)/usr/lib/linux-tools
	$(LN) ../$(DEB_SOURCE)-tools-$(abi_release) $(cloudpkgdir)/usr/lib/linux-tools/$(abi_release)-$*
 endif
endif

	# Build a temporary "installed headers" directory.
	install -d $(dkms_dir) $(dkms_dir)/headers $(dkms_dir)/build $(dkms_dir)/source
	cp -rp "$(hdrdir)" "$(indep_hdrdir)" "$(dkms_dir)/headers"

	$(foreach _m,$(all_dkms_modules), \
	  $(if $(enable_$(_m)), \
	    $(call build_dkms,$(dkms_$(_m)_pkg_name)-$*,$(dkms_$(_m)_pkgdir)/lib/modules/$(abi_release)-$*/$(dkms_$(_m)_subdir),$(dbgpkgdir_dkms),$(_m),$(dkms_$(_m)_debpath)); \
	  ) \
	)


ifeq ($(do_dbgsym_package),true)
	# Add .gnu_debuglink sections to each stripped .ko
	# pointing to unstripped verson
	find $(pkgdir) \
	  $(if $(filter true,$(do_extras_package)),$(pkgdir_ex)) \
	  -name '*.ko' | while read path_module ; do \
		module="/lib/modules/$${path_module#*/lib/modules/}"; \
		if [[ -f "$(dbgpkgdir)/usr/lib/debug/$$module" ]] ; then \
			while IFS= read -r -d '' signature < <(tail -c 28 "$$path_module"); do \
				break; \
			done; \
			$(CROSS_COMPILE)objcopy \
				--add-gnu-debuglink=$(dbgpkgdir)/usr/lib/debug/$$module \
				$$path_module; \
			if grep -q CONFIG_MODULE_SIG=y $(build_dir)/.config && \
			   [ "$$signature" = $$'~Module signature appended~\n' ]; then \
				$(build_dir)/scripts/sign-file $(MODHASHALGO) \
					$(MODSECKEY) \
					$(MODPUBKEY) \
					$$path_module; \
			fi; \
		else \
			echo "WARNING: Missing debug symbols for module '$$module'."; \
		fi; \
	done
endif

	# Build the final ABI information.
	install -d $(abi_dir)
	sed -e 's/^\(.\+\)[[:space:]]\+\(.\+\)[[:space:]]\(.\+\)$$/\3 \2 \1/'	\
		$(build_dir)/Module.symvers | sort > $(abi_dir)/$*

	# Build the final ABI modules information.
	find $(pkgdir_bin) $(pkgdir) $(pkgdir_ex) \( -name '*.ko' -o -name '*.ko.*' \) | \
		sed -e 's/.*\/\([^\/]*\)\.ko.*/\1/' | sort > $(abi_dir)/$*.modules

	# Build the final ABI built-in modules information.
	if [ -f $(pkgdir)/lib/modules/$(abi_release)-$*/modules.builtin ] ; then \
		sed -e 's/.*\/\([^\/]*\)\.ko/\1/' $(pkgdir)/lib/modules/$(abi_release)-$*/modules.builtin | \
			sort > $(abi_dir)/$*.modules.builtin; \
	fi

	# Build the final ABI firmware information.
	find $(pkgdir_bin) $(pkgdir) $(pkgdir_ex) -name \*.ko | \
	while read ko; do \
		/sbin/modinfo $$ko | grep ^firmware || true; \
	done | sort -u >$(abi_dir)/$*.fwinfo

	# Build the final ABI built-in firmware information.
	if [ -f $(pkgdir)/lib/modules/$(abi_release)-$*/modules.builtin.modinfo ] ; then \
		cat $(pkgdir)/lib/modules/$(abi_release)-$*/modules.builtin.modinfo | \
			tr '\0' '\n' | sed -n 's/^.*firmware=/firmware: /p' | \
			sort -u > $(abi_dir)/$*.fwinfo.builtin; \
	fi

	# Build the final ABI compiler information.
	ko=$$(find $(pkgdir_bin) $(pkgdir) $(pkgdir_ex) -name \*.ko | head -1); \
	readelf -p .comment "$$ko" | gawk ' \
		($$1 == "[") { \
			printf("%s", $$3); \
			for (n=4; n<=NF; n++) { \
				printf(" %s", $$n); \
			} \
			print "" \
		}' | sort -u >$(abi_dir)/$*.compiler

	# Build the buildinfo package content.
	install -d $(pkgdir_bldinfo)/usr/lib/linux/$(abi_release)-$*
	install -m644 $(build_dir)/.config \
		$(pkgdir_bldinfo)/usr/lib/linux/$(abi_release)-$*/config
	install -m644 $(abi_dir)/$* \
		$(pkgdir_bldinfo)/usr/lib/linux/$(abi_release)-$*/abi
	install -m644 $(abi_dir)/$*.modules \
		$(pkgdir_bldinfo)/usr/lib/linux/$(abi_release)-$*/modules
	install -m644 $(abi_dir)/$*.fwinfo \
		$(pkgdir_bldinfo)/usr/lib/linux/$(abi_release)-$*/fwinfo
	install -m644 $(abi_dir)/$*.compiler \
		$(pkgdir_bldinfo)/usr/lib/linux/$(abi_release)-$*/compiler
	if [ -f $(abi_dir)/$*.modules.builtin ] ; then \
		install -m644 $(abi_dir)/$*.modules.builtin \
			$(pkgdir_bldinfo)/usr/lib/linux/$(abi_release)-$*/modules.builtin; \
	fi
	if [ -f $(abi_dir)/$*.fwinfo.builtin ] ; then \
		install -m644 $(abi_dir)/$*.fwinfo.builtin \
			$(pkgdir_bldinfo)/usr/lib/linux/$(abi_release)-$*/fwinfo.builtin; \
	fi
	install -m644 debian/canonical-certs.pem $(pkgdir_bldinfo)/usr/lib/linux/$(abi_release)-$*/canonical-certs.pem
	install -m644 debian/canonical-revoked-certs.pem $(pkgdir_bldinfo)/usr/lib/linux/$(abi_release)-$*/canonical-revoked-certs.pem
	# List of source files used for this build
	install -m644 $(build_dir)/sources.list $(pkgdir_bldinfo)/usr/lib/linux/$(abi_release)-$*/sources

	# Get rid of .o and .cmd artifacts in headers
	find $(hdrdir) -name \*.o -or -name \*.cmd -exec rm -f {} \;
	# Strip .so files (e.g., rust/libmacros.so) to reduce size even more
	find $(hdrdir) -name libmacros.so -exec strip -s {} \;

ifeq ($(do_lib_rust),true)
	# Generate Rust lib files
	install -d -m755 $(rustdir)
	mv $(hdrdir)/rust $(rustdir)
	# Generate symlink for Rust lib directory in headers
	$(SHELL) debian/scripts/link-lib-rust "$(hdrdir)" "$(indeppkg)" "$*"
endif

ifneq ($(do_full_build),false)
	# Clean out this flavours build directory.
	rm -rf $(build_dir)
	rm -rf $(abi_dir)
endif
	$(stamp)

headers_dir := $(CURDIR)/debian/linux-libc-dev

$(stampdir)/stamp-install-arch-headers: headers_tmp = $(CURDIR)/debian/tmp-headers
$(stampdir)/stamp-install-arch-headers:
	@echo Debug: $@
	dh_testdir
	dh_testroot
	$(call if_package, linux-libc-dev, dh_prep -plinux-libc-dev)
	rm -rf $(headers_tmp) $(headers_dir)
	$(kmake) O=$(headers_tmp) INSTALL_HDR_PATH=$(headers_dir)/usr $(conc_level) headers_install
	mkdir $(headers_dir)/usr/include/$(DEB_HOST_MULTIARCH)
	mv $(headers_dir)/usr/include/asm $(headers_dir)/usr/include/$(DEB_HOST_MULTIARCH)/
	rm -rf $(headers_tmp)
	$(stamp)

define dh_all
	dh_installchangelogs -p$(1)
	dh_installdocs -p$(1)
	dh_compress -p$(1)
	# Compress kernel modules, on mantic+
	$(if $(do_zstd_ko),find debian/$(1) -name '*.ko' -print0 | xargs -0 -n1 -P $(CONCURRENCY_LEVEL) -r zstd -19 --quiet --rm, true)
	dh_fixperms -p$(1) -X/boot/
	dh_shlibdeps -p$(1) $(shlibdeps_opts)
	dh_installdeb -p$(1)
	dh_installdebconf -p$(1)
	$(lockme) dh_gencontrol -p$(1) -- -Vlinux:rprovides='$(rprovides)' $(2)
	dh_md5sums -p$(1)
	dh_builddeb -p$(1)
endef
define newline


endef
define dh_all_inline
        $(subst ${newline},; \${newline},$(call dh_all,$(1),$(2)))
endef

.PHONY: binary-arch-headers
binary-arch-headers: $(stampdir)/stamp-install-arch-headers
	@echo Debug: $@
	dh_testdir
	dh_testroot
	$(call if_package, linux-libc-dev, $(call dh_all,linux-libc-dev))

-include $(builddir)/skipped-dkms.mk
binary-%: pkgimg = $(bin_pkg_name)-$*
binary-%: pkgimg_mods = $(mods_pkg_name)-$*
binary-%: pkgimg_ex = $(mods_extra_pkg_name)-$*
binary-%: pkgbldinfo = $(bldinfo_pkg_name)-$*
binary-%: pkghdr = $(hdrs_pkg_name)-$*
binary-%: pkgrust = $(rust_pkg_name)-$*
binary-%: dbgpkg = $(bin_pkg_name)-$*-dbgsym
binary-%: dbgpkgdir = $(CURDIR)/debian/$(bin_pkg_name)-$*-dbgsym
binary-%: pkgtools = $(tools_flavour_pkg_name)-$*
binary-%: pkgcloud = $(cloud_flavour_pkg_name)-$*
$(foreach _m,$(all_dkms_modules), \
  $(eval binary-%: enable_$(_m) = $$(filter true,$$(call custom_override,do_$(_m),$$*))) \
)
binary-%: rprovides = $(foreach _m,$(all_built-in_dkms_modules),$(if $(enable_$(_m)),$(foreach _r,$(dkms_$(_m)_rprovides),$(_r)$(comma) )))
binary-%: $(stampdir)/stamp-install-%
	@echo Debug: $@
	dh_testdir
	dh_testroot

	$(call dh_all,$(pkgimg)) -- -Znone
	$(call dh_all,$(pkgimg_mods))$(if $(do_zstd_ko), -- -Znone)

ifeq ($(do_extras_package),true)
	if [ -f $(DEBIAN)/control.d/$*.inclusion-list ] ; then \
		$(call dh_all_inline,$(pkgimg_ex))$(if $(do_zstd_ko), -- -Znone); \
	fi
endif

	$(foreach _m,$(all_standalone_dkms_modules), \
	  $(if $(enable_$(_m)),$(call dh_all,$(dkms_$(_m)_pkg_name)-$*)$(if $(do_zstd_ko), -- -Znone);)\
	)

	$(call dh_all,$(pkgbldinfo))
	$(call dh_all,$(pkghdr))
ifeq ($(do_lib_rust),true)
	$(call dh_all,$(pkgrust))
endif

ifeq ($(do_dbgsym_package),true)
	$(call dh_all,$(dbgpkg)) -- -Zxz

	# Hokay...here's where we do a little twiddling...
	# Renaming the debug package prevents it from getting into
	# the primary archive, and therefore prevents this very large
	# package from being mirrored. It is instead, through some
	# archive admin hackery, copied to http://ddebs.ubuntu.com.
	#
	mv ../$(dbgpkg)_$(DEB_VERSION_UPSTREAM)-$(DEB_REVISION)_$(arch).deb \
		../$(dbgpkg)_$(DEB_VERSION_UPSTREAM)-$(DEB_REVISION)_$(arch).ddeb
	$(lockme) sed -i '/^$(dbgpkg)_/s/\.deb /.ddeb /' debian/files
	# Now, the package wont get into the archive, but it will get put
	# into the debug system.

	# Clean out the debugging package source directory.
	rm -rf $(dbgpkgdir)
endif

ifeq ($(do_linux_tools),true)
	$(call dh_all,$(pkgtools))
endif
ifeq ($(do_cloud_tools),true)
	$(call dh_all,$(pkgcloud))
endif
ifeq ($(do_linux_tools),true)
 ifeq ($(do_tools_bpftool),true)
  ifneq ($(filter linux-bpf-dev,$(packages_enabled)),)
	# Do this only for the primary (first) flavor
	# linux-bpf-dev is broken: It provides vmlinux.h which is a flavored header file!
	if [ $* = $(firstword $(flavours)) ] ; then \
		$(call dh_all_inline,linux-bpf-dev) ; \
	fi
  endif
 endif
endif

#
# per-architecture packages
#
builddirpa = $(builddir)/tools-perarch

$(stampdir)/stamp-prepare-perarch:
	@echo Debug: $@
ifeq ($(do_any_tools),true)
	rm -rf $(builddirpa)
	install -d $(builddirpa)
	rsync -a --exclude debian --exclude debian.master --exclude $(DEBIAN) --exclude .git -a ./ $(builddirpa)/
endif
	$(stamp)

$(stampdir)/stamp-build-perarch: $(stampdir)/stamp-install-arch-headers $(stampdir)/stamp-prepare-perarch
	@echo Debug: $@
ifeq ($(do_linux_tools),true)
ifeq ($(do_tools_usbip),true)
	chmod 755 $(builddirpa)/tools/usb/usbip/autogen.sh
	cd $(builddirpa)/tools/usb/usbip && ./autogen.sh
	chmod 755 $(builddirpa)/tools/usb/usbip/configure
	cd $(builddirpa)/tools/usb/usbip && ./configure --prefix=$(builddirpa)/tools/usb/usbip/bin
	cd $(builddirpa)/tools/usb/usbip && make install CFLAGS="-g -O2 -static" CROSS_COMPILE=$(CROSS_COMPILE)
endif
ifeq ($(do_tools_acpidbg),true)
	cd $(builddirpa)/tools/power/acpi && make clean && make CFLAGS="-g -O2 -static -I$(builddirpa)/include" CROSS_COMPILE=$(CROSS_COMPILE) acpidbg
endif
ifeq ($(do_tools_rtla),true)
	cd $(builddirpa) && $(kmake) -C tools/tracing/rtla clean && $(kmake) LD=ld -C tools/tracing/rtla static
endif
ifeq ($(do_tools_cpupower),true)
	make -C $(builddirpa)/tools/power/cpupower \
		CROSS_COMPILE=$(CROSS_COMPILE) \
		CROSS=$(CROSS_COMPILE) \
		STATIC=true \
		CPUFREQ_BENCH=false
endif
ifeq ($(do_tools_perf),true)
	cd $(builddirpa)/tools/perf && \
		$(kmake) prefix=/usr HAVE_CPLUS_DEMANGLE_SUPPORT=1 CROSS_COMPILE=$(CROSS_COMPILE) NO_LIBPERL=1 WERROR=0
endif
ifeq ($(do_tools_bpftool),true)
	$(kmake) CROSS_COMPILE=$(CROSS_COMPILE) -C $(builddirpa)/tools/bpf/bpftool
endif
ifeq ($(do_tools_x86),true)
	cd $(builddirpa)/tools/power/x86/x86_energy_perf_policy && make CROSS_COMPILE=$(CROSS_COMPILE)
	cd $(builddirpa)/tools/power/x86/turbostat && make CROSS_COMPILE=$(CROSS_COMPILE)
endif
endif
ifeq ($(do_cloud_tools),true)
ifeq ($(do_tools_hyperv),true)
	cd $(builddirpa)/tools/hv && make CFLAGS="-I$(headers_dir)/usr/include -I$(headers_dir)/usr/include/$(DEB_HOST_MULTIARCH)" CROSS_COMPILE=$(CROSS_COMPILE) hv_kvp_daemon hv_vss_daemon
ifneq ($(build_arch),arm64)
	cd $(builddirpa)/tools/hv && make CFLAGS="-I$(headers_dir)/usr/include -I$(headers_dir)/usr/include/$(DEB_HOST_MULTIARCH)" CROSS_COMPILE=$(CROSS_COMPILE) hv_fcopy_uio_daemon
endif
endif
endif
	$(stamp)

.PHONY: install-perarch
install-perarch: toolspkgdir = $(CURDIR)/debian/$(tools_pkg_name)
install-perarch: cloudpkgdir = $(CURDIR)/debian/$(cloud_pkg_name)
install-perarch: $(stampdir)/stamp-build-perarch
	@echo Debug: $@
	# Add the tools.
ifeq ($(do_linux_tools),true)
	install -d $(toolspkgdir)/usr/lib/$(DEB_SOURCE)-tools-$(abi_release)
	install -d $(toolspkgdir)/usr/lib/$(DEB_SOURCE)-tools-$(abi_release)/lib
ifeq ($(do_tools_usbip),true)
	install -m755 $(addprefix $(builddirpa)/tools/usb/usbip/bin/sbin/, usbip usbipd) \
		$(toolspkgdir)/usr/lib/$(DEB_SOURCE)-tools-$(abi_release)
endif
ifeq ($(do_tools_acpidbg),true)
	install -m755 $(builddirpa)/tools/power/acpi/acpidbg \
		$(toolspkgdir)/usr/lib/$(DEB_SOURCE)-tools-$(abi_release)
endif
ifeq ($(do_tools_cpupower),true)
	install -m755 $(builddirpa)/tools/power/cpupower/cpupower \
		$(toolspkgdir)/usr/lib/$(DEB_SOURCE)-tools-$(abi_release)
endif
ifeq ($(do_tools_rtla),true)
	install -m755 $(builddirpa)/tools/tracing/rtla/rtla-static \
		$(toolspkgdir)/usr/lib/$(DEB_SOURCE)-tools-$(abi_release)/rtla
endif
ifeq ($(do_tools_perf),true)
	install -m755 $(builddirpa)/tools/perf/perf \
		$(toolspkgdir)/usr/lib/$(DEB_SOURCE)-tools-$(abi_release)
ifeq ($(do_tools_perf_jvmti),true)
	install -m644 $(builddirpa)/tools/perf/libperf-jvmti.so \
		$(toolspkgdir)/usr/lib/$(DEB_SOURCE)-tools-$(abi_release)/lib
endif
ifeq ($(do_tools_perf_python),true)
	install -m644 $(builddirpa)/tools/perf/python/perf.*.so \
		$(toolspkgdir)/usr/lib/$(DEB_SOURCE)-tools-$(abi_release)/lib
endif
endif # do_tools_perf
ifeq ($(do_tools_bpftool),true)
	install -m755 $(builddirpa)/tools/bpf/bpftool/bpftool \
		$(toolspkgdir)/usr/lib/$(DEB_SOURCE)-tools-$(abi_release)
endif
ifeq ($(do_tools_x86),true)
	install -m755 $(addprefix $(builddirpa)/tools/power/x86/, x86_energy_perf_policy/x86_energy_perf_policy turbostat/turbostat) \
		$(toolspkgdir)/usr/lib/$(DEB_SOURCE)-tools-$(abi_release)
endif
endif # do_linux_tools
ifeq ($(do_cloud_tools),true)
ifeq ($(do_tools_hyperv),true)
	install -d $(cloudpkgdir)/usr/lib/$(DEB_SOURCE)-tools-$(abi_release)
	install -m755 $(addprefix $(builddirpa)/tools/hv/, hv_kvp_daemon hv_vss_daemon lsvmbus) \
		$(cloudpkgdir)/usr/lib/$(DEB_SOURCE)-tools-$(abi_release)
ifneq ($(build_arch),arm64)
	install -m755 $(addprefix $(builddirpa)/tools/hv/, hv_fcopy_uio_daemon) \
		$(cloudpkgdir)/usr/lib/$(DEB_SOURCE)-tools-$(abi_release)
endif
endif # do_tools_hyperv
endif # do_cloud_tools

.PHONY: binary-perarch
binary-perarch: toolspkg = $(tools_pkg_name)
binary-perarch: cloudpkg = $(cloud_pkg_name)
binary-perarch: install-perarch
	@echo Debug: $@
ifeq ($(do_linux_tools),true)
	$(call dh_all,$(toolspkg))
endif
ifeq ($(do_cloud_tools),true)
	$(call dh_all,$(cloudpkg))
endif

.PHONY: binary-debs
binary-debs: binary-perarch $(addprefix binary-,$(flavours))
	@echo Debug: $@

build-arch-deps-$(do_flavour_image_package) += $(addprefix $(stampdir)/stamp-install-,$(flavours))

.PHONY: build-arch
build-arch: $(build-arch-deps-true)
	@echo Debug: $@

binary-arch-deps-$(do_flavour_image_package) += binary-debs
binary-arch-deps-true += binary-arch-headers
ifneq ($(do_common_headers_indep),true)
binary-arch-deps-$(do_flavour_header_package) += binary-headers
endif

.PHONY: binary-arch
binary-arch: $(binary-arch-deps-true)
	@echo Debug: $@

