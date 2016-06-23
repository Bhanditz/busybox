FROM alpine:3.3

RUN apk add --no-cache \
		bzip2 \
		curl \
		gcc \
		make \
		\
		gnupg \
		linux-headers \
		musl-dev

# pub   1024D/ACC9965B 2006-12-12
#       Key fingerprint = C9E9 416F 76E6 10DB D09D  040F 47B7 0C55 ACC9 965B
# uid                  Denis Vlasenko <vda.linux@googlemail.com>
# sub   1024g/2C766641 2006-12-12
RUN gpg --keyserver pool.sks-keyservers.net --recv-keys C9E9416F76E610DBD09D040F47B70C55ACC9965B

ENV BUSYBOX_VERSION 1.25.0

RUN set -x \
	&& curl -fsSL "http://busybox.net/downloads/busybox-${BUSYBOX_VERSION}.tar.bz2" -o busybox.tar.bz2 \
	&& curl -fsSL "http://busybox.net/downloads/busybox-${BUSYBOX_VERSION}.tar.bz2.sign" -o busybox.tar.bz2.sign \
	&& gpg --verify busybox.tar.bz2.sign \
	&& tar -xjf busybox.tar.bz2 \
	&& mkdir -p /usr/src \
	&& mv "busybox-${BUSYBOX_VERSION}" /usr/src/busybox \
	&& rm busybox.tar.bz2*

WORKDIR /usr/src/busybox

# https://www.mail-archive.com/toybox@lists.landley.net/msg02528.html
# https://www.mail-archive.com/toybox@lists.landley.net/msg02526.html
RUN sed -i 's/^struct kconf_id \*$/static &/g' scripts/kconfig/zconf.hash.c_shipped

# see http://wiki.musl-libc.org/wiki/Building_Busybox
# TODO remove CONFIG_FEATURE_SYNC_FANCY from this explicit list after the next release of busybox (since it's disabled by default upstream now)
RUN yConfs=' \
		CONFIG_AR \
		CONFIG_FEATURE_AR_LONG_FILENAMES \
		CONFIG_FEATURE_AR_CREATE \
		CONFIG_STATIC \
	' \
	&& nConfs=' \
		CONFIG_FEATURE_SYNC_FANCY \
		\
		CONFIG_FEATURE_HAVE_RPC \
		CONFIG_FEATURE_INETD_RPC \
		CONFIG_FEATURE_UTMP \
		CONFIG_FEATURE_WTMP \
	' \
	&& set -xe \
	&& make defconfig \
	&& for conf in $nConfs; do \
		sed -i "s!^$conf=y!# $conf is not set!" .config; \
	done \
	&& for conf in $yConfs; do \
		sed -i "s!^# $conf is not set\$!$conf=y!" .config; \
		grep -q "^$conf=y" .config || echo "$conf=y" >> .config; \
	done \
	&& make oldconfig \
	&& for conf in $nConfs; do \
		! grep -q "^$conf=y" .config; \
	done \
	&& for conf in $yConfs; do \
		grep -q "^$conf=y" .config; \
	done

RUN set -x \
	&& make -j$(getconf _NPROCESSORS_ONLN) \
		busybox \
	&& ./busybox --help \
	&& mkdir -p rootfs/bin \
	&& ln -v busybox rootfs/bin/ \
	&& chroot rootfs /bin/busybox --install /bin

# grab a simplified getconf port from Alpine we can statically compile
RUN set -x \
	&& aportsVersion="v$(cat /etc/alpine-release)" \
	&& curl -fsSL \
		"http://git.alpinelinux.org/cgit/aports/plain/main/musl/getconf.c?h=${aportsVersion}" \
		-o /usr/src/getconf.c \
	&& gcc -o rootfs/bin/getconf -static -Os /usr/src/getconf.c \
	&& chroot rootfs /bin/sh -xec 'getconf _NPROCESSORS_ONLN'

RUN set -ex \
	&& buildrootVersion='2015.11.1' \
	&& mkdir -p rootfs/etc \
	&& for f in passwd shadow group; do \
		curl -fSL \
			"http://git.busybox.net/buildroot/plain/system/skeleton/etc/$f?id=$buildrootVersion" \
			-o "rootfs/etc/$f"; \
	done

# create /tmp
RUN mkdir -p rootfs/tmp \
	&& chmod 1777 rootfs/tmp

# create missing home directories
RUN set -ex \
	&& cd rootfs \
	&& for userHome in $(awk -F ':' '{ print $3 ":" $4 "=" $6 }' etc/passwd); do \
		user="${userHome%%=*}"; \
		home="${userHome#*=}"; \
		home="./${home#/}"; \
		if [ ! -d "$home" ]; then \
			mkdir -p "$home"; \
			chown "$user" "$home"; \
		fi; \
	done

# test and make sure it works
RUN chroot rootfs /bin/sh -xec 'true'

# ensure correct timezone (UTC)
RUN ln -v /etc/localtime rootfs/etc/ \
	&& [ "$(chroot rootfs date +%Z)" = 'UTC' ]

# test and make sure DNS works too
RUN cp -L /etc/resolv.conf rootfs/etc/ \
	&& chroot rootfs /bin/sh -xec 'nslookup google.com' \
	&& rm rootfs/etc/resolv.conf
