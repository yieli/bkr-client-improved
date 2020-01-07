#!/bin/bash
# Description: to install brew scratch build or 3rd party pkgs
# Author: Jianhong Yin <jiyin@redhat.com>

LANG=C
baseDownloadUrl=https://raw.githubusercontent.com/tcler/bkr-client-improved/master

is_available_url() {
        local _url=$1
        curl --connect-timeout 8 -m 16 --output /dev/null --silent --head --fail $_url &>/dev/null
}
is_intranet() {
	local iurl=http://download.devel.redhat.com
	is_available_url $iurl
}

[[ function = "$(type -t report_result)" ]] || report_result() {  echo "$@"; }

P=${0##*/}
KREBOOT=yes
retcode=0
res=PASS
prompt="[brew-install]"
run() {
	local cmdline=$1
	local expect_ret=${2:-0}
	local comment=${3:-$cmdline}
	local ret=0

	echo "[$(date +%T) $USER@ ${PWD%%*/}]# $cmdline"
	eval $cmdline
	ret=$?
	[[ $expect_ret != - && $expect_ret != $ret ]] && {
		report_result "$comment" FAIL
		let retcode++
	}

	return $ret
}

Usage() {
	cat <<-EOF
	Usage:
	 $P <[brew_scratch_build_id] | [lstk|upk|brew_build_name] | [url]>  [-debugk] [-noreboot] [-depthLevel=\${N:-2}] [-debuginfo] [-onlydebuginfo] [-onlydownload] [-arch=\$arch]

	Example:
	 $P 23822847  # brew scratch build id
	 $P kernel-4.18.0-147.8.el8    # brew build name
	 $P [ftp|http]://url/xyz.rpm   # install xyz.rpm
	 $P nfs:server/nfsshare        # install all rpms in nfsshare
	 $P lstk                       # install latest release kernel
	 $P lstk -debuginfo            # install latest release kernel and it's -debuginfo package
	 $P lstk -debugk               # install latest release debug kernel
	 $P upk                        # install latest upstream kernel
	 $P [ftp|http]://url/path/ [-depthLevel=N]  # install all rpms in url/path, default download depth level 2
	 $P kernel-4.18.0-148.el8 -onlydebuginfo    # install -debuginfo pkg of kernel-4.18.0-148.el8
	 $P -onlydownload [other option] <args>     # only download rpms and exit
	 $P -onlydownload -arch=src,noarch kernel-4.18.0-148.el8  # only download src and noarch package of build kernel-4.18.0-148.el8
EOF
}

# Install scratch build package
[ -z "$*" ] && {
	Usage >&2
	exit
}

is_intranet && {
	Intranet=yes
	baseDownloadUrl=http://download.devel.redhat.com/qa/rhts/lookaside/bkr-client-improved
}

install_brew() {
	which brew &>/dev/null || {
		which brewkoji_install.sh &>/dev/null || {
			_url=$baseDownloadUrl/utils/brewkoji_install.sh
			mkdir -p ~/bin && curl -o ~/bin/brewkoji_install.sh -s -L $_url
			chmod +x ~/bin/brewkoji_install.sh
		}
		PATH=~/bin:$PATH brewkoji_install.sh >/dev/null || {
			echo "{WARN} install brewkoji failed" >&2
			exit 1
		}
	}
}

# parse options
builds=()
for arg; do
	case "$arg" in
	-debuginfo)      DEBUG_INFO_OPT=--debuginfo;;
	-onlydebuginfo)  DEBUG_INFO_OPT=--debuginfo; ONLY_DEBUG_INFO=yes; KREBOOT=no;;
	-onlydownload)   ONLY_DOWNLOAD=yes;;
	-debug|-debugk*) FLAG=debugkernel;;
	-noreboot*)      KREBOOT=no;;
	-depthLevel=*)   depthLevel=${arg/*=/};;
	-arch=*)         _ARCH=${arg/*=/};;
	-h)              Usage; exit;;
	-*)              echo "{WARN} unkown option '${arg}'";;
	*)
		curknvr=kernel-$(uname -r)
		if [[ "$arg" = ${curknvr%.*} && "$*" != *-debug* ]]; then
			report_result ${arg}--has-been-installed--kernel-$(uname -r) PASS
		else
			builds+=($arg)
		fi
		;;
	esac
done

if [[ "${#builds[@]}" = 0 ]]; then
	if [[ "$FLAG" = debugkernel ]]; then
		builds+=(kernel-$(uname -r|sed 's/\.[^.]*$//'))
	else
		Usage >&2
		exit
	fi
fi

run install_brew -

archList=($(arch) noarch)
[[ -n "$_ARCH" ]] && archList=(${_ARCH//,/ })
archPattern=$(echo "${archList[*]}"|sed 's/ /|/g')
wgetOpts=$(for a in "${archList[@]}"; do echo -n " -A.${a}.rpm"; done)

# Download packges
depthLevel=${DEPTH_LEVEL:-2}
for build in "${builds[@]}"; do
	[[ "$build" = -* ]] && { continue; }

	[[ "$build" = upk ]] && {
		builds=($(brew search build "kernel-*.elrdy" | sort -Vr | head -n3))
		for B in "${builds[@]}"; do
			if brew buildinfo $B | grep -q '.*\.rpm$'; then
				build=$B
				break
			fi
		done
	}
	[[ "$build" = lstk ]] && {
		read ver rel < <(rpm -q --qf '%{version} %{release}\n' kernel-$(uname -r))
		builds=($(brew search build kernel-$ver-${rel/*./*.} | sort -Vr | head -n3))
		for B in "${builds[@]}"; do
			if brew buildinfo $B | grep -q '.*\.rpm$'; then
				build=$B
				break
			fi
		done
	}

	if [[ "$build" =~ ^[0-9]+$ ]]; then
		taskid=${build}
		#wait the scratch build finish
		while brew taskinfo $taskid|grep -q '^State: open'; do echo "[$(date +%T) Info] build hasn't finished, wait"; sleep 5m; done

		run "brew taskinfo -r $taskid > >(tee brew_taskinfo.txt)"
		run "awk '/\\<($archPattern)\\.rpm/{print}' brew_taskinfo.txt >buildArch.txt"
		run "cat buildArch.txt"

		: <<-'COMM'
		[ -z "$(< buildArch.txt)" ] && {
			echo "$prompt [Warn] rpm not found, treat the [$taskid] as build ID."
			buildid=$taskid
			run "brew buildinfo $buildid > >(tee brew_buildinfo.txt)"
			run "awk '/\\<($archPattern)\\.rpm/{print}' brew_buildinfo.txt >buildArch.txt"
			run "cat buildArch.txt"
		}
		COMM

		urllist=$(sed '/mnt.redhat..*rpm$/s; */mnt/redhat/;;' buildArch.txt)
		for url in $urllist; do
			run "curl -O -L http://download.devel.redhat.com/$url" 0  "download-${url##*/}"
		done

		#try download rpms from brew download server
		[[ -z "$urllist" ]] && {
			owner=$(awk '/^Owner:/{print $2}' brew_taskinfo.txt)
			downloadServerUrl=http://download.devel.redhat.com/brewroot/scratch/$owner/task_$taskid
			is_available_url $downloadServerUrl && {
				finalUrl=$(curl -Ls -o /dev/null -w %{url_effective} $downloadServerUrl)
				which wget &>/dev/null || yum install -y wget
				run "wget -r -l$depthLevel --no-parent $wgetOpts --progress=dot:mega $finalUrl" 0  "download-${finalUrl##*/}"
				find */ -name '*.rpm' | xargs -i mv {} ./
			}
		}
	elif [[ "$build" =~ ^nfs: ]]; then
		nfsmp=/mnt/nfsmountpoint-$$
		mkdir -p $nfsmp
		nfsaddr=${build/nfs:/}
		nfsserver=${nfsaddr%:/*}
		exportdir=${nfsaddr#*:/}
		which mount.nfs &>/dev/null ||
			yum install -y nfs-utils
		run "mount $nfsserver:/ $nfsmp"
		for a in "${archList[@]}"; do
			ls $nfsmp/$exportdir/*.${a}.rpm &&
				run "cp -f $nfsmp/$exportdir/*.${a}.rpm ."
		done
		run "umount $nfsmp" -
	elif [[ "$build" =~ ^(ftp|http|https):// ]]; then
		for url in $build; do
			if [[ $url = *.rpm ]]; then
				run "curl -O -L $url" 0  "download-${url##*/}"
			else
				which wget &>/dev/null || yum install -y wget
				run "wget -r -l$depthLevel --no-parent $wgetOpts --progress=dot:mega $url" 0  "download-${url##*/}"
				find */ -name '*.rpm' | xargs -i mv {} ./
			fi
		done
	else
		buildname=$build
		for a in "${archList[@]}"; do
			run "brew download-build $DEBUG_INFO_OPT $buildname --arch=${a}" -
		done
	fi
done

# Install packages
run "ls -lh"
run "ls -lh *.rpm"
[ $? != 0 ] && {
	report_result download-rpms FAIL
	exit 1
}

[[ "$ONLY_DOWNLOAD" = yes ]] && {
	exit 0
}

for rpm in *.rpm; do
	[[ "$ONLY_DEBUG_INFO" = yes && $rpm != *-debuginfo-* ]] && {
		rm -f $rpm
		continue
	}
	run "rpm -Uvh --force --nodeps $rpm" -
done

# if include debug in FLAG
[[ "$FLAG" =~ debugkernel ]] && {
	if [ -x /sbin/grubby -o -x /usr/sbin/grubby ]; then
		VRA=$(rpm -qp --qf '%{version}-%{release}.%{arch}' $(ls kernel-debug*rpm | head -1))
		run "grubby --set-default /boot/vmlinuz-${VRA}*debug"
	elif [ -x /usr/sbin/grub2-set-default ]; then
		run "grub2-set-default $(grep ^menuentry /boot/grub2/grub.cfg | cut -f 2 -d \' | nl -v 0 | awk '/\.debug)/{print $1}')"
	elif [ -x /usr/sbin/grub-set-default ]; then
		run "grub-set-default $(grep '^[[:space:]]*kernel' /boot/grub/grub.conf | nl -v 0 | awk '/\.debug /{print $1}')"
	fi
}

if ls *.$(arch).rpm|grep '^kernel-[0-9]'; then
	[[ "$KREBOOT" = yes ]] && reboot
fi
