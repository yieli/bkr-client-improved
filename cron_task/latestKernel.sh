#!/bin/bash
#author: jiyin@redhat.com

# https://en.wikichip.org/wiki/irc/colors
ircBold=$'\x02'
ircItalics=$'\x1D'
ircUnderline=$'\x1F'
ircReverse=$'\x16'
ircPlain=$'\x0F'

ircWhite=$'\x03'00
ircBlack=$'\x03'01
ircNavy=$'\x03'02
ircGreen=$'\x03'03
ircRed=$'\x03'04
ircMaroon=$'\x03'05
ircPurple=$'\x03'06
ircOlive=$'\x03'07
ircYellow=$'\x03'08
ircLightGreen=$'\x03'09
ircTeal=$'\x03'10
ircCyan=$'\x03'11
ircRoyalblue=$'\x03'12
ircMagenta=$'\x03'13
ircGray=$'\x03'14
ircLightGray=$'\x03'15

mkdir -p /var/cache/kernelnvrDB
pushd /var/cache/kernelnvrDB  >/dev/null

from="kernel monitor <from@redhat.com>"
mailTo=fs@redhat.com
mailCc=net@redhat.com
kgitDir=/home/yjh/ws/code.repo
VLIST="6 7 8"
latestKernelF=.latest.kernel
kfList=$(eval echo $latestKernelF-{${VLIST// /,}})
#echo $kfList
debug=$1

searchBrewBuild '^kernel-[.0-9]+-[0-9]+.el'"[${VLIST// /}]"'$' >.kernelList
test -n "`cat .kernelList`" &&
	for V in ${VLIST}; do
	    L=$(egrep 'kernel-[-.0-9]+el'$V .kernelList | head -n4)
	    echo "$L" > ${latestKernelF}-$V.tmp
	done

for f in $kfList; do
	[ ! -f ${f}.tmp ] && continue
	[ $(stat -c %s ${f}.tmp) = 0 ] && continue

	# previous log of kernel list doesn't exist
	[ ! -f ${f} ] && {
		mv ${f}.tmp ${f}
		continue
	}
	[ -n "$debug" ] && {
		echo
		cat ${f}.tmp
		diff -pNur -w ${f} ${f}.tmp | sed 's/^/\t/'
		rm -f ${f}.tmp
		continue
	}

	V=${f#*-}
	newkernel=
	available=0
	patch=${PWD}/${f}.patch

	# check if there's any difference
	diff -pNur -w $f ${f}.tmp >$patch && continue
	sed -i '/^[^+]/d;/^+++/d' $patch
	while read -r line; do
		nvr=${line#+}
		if [ "$(stateBrewBuild $nvr)" != "COMPLETE" ]; then
			# remove build whose state is not complete
			perl -ni -e "print unless /${nvr}$/" ${patch} ${f}.tmp
		fi
	done < "$patch"
	grep '^+[^+]' ${patch} || continue
	# print in reverse to show the newer vers afterward
	newkernel=$(tac ${patch} | sed 's/^+//')

	#url=http://patchwork.lab.bos.redhat.com/status/rhel${V}/changelog.html
	url=ftp://fs-qe.usersys.redhat.com/pub/kernel-changelog/changeLog-$V.html

	# send email
	echo >>$patch
	echo "#-------------------------------------------------------------------------------" >>$patch
	echo "# $url" >>$patch
	for nvr in $newkernel; do
		echo -e "{Info} ${nvr} changelog read from pkg:"
		brewinstall.sh $nvr -onlydownload -arch=src >/dev/null
		[ -f ${nvr}.src.rpm ] && available=1
		LANG=C rpm -qp --changelog ${nvr}.src.rpm >changeLog-$V
		[ -s changeLog-$V ] && {
			cp -f changeLog-$V /var/ftp/pub/kernel-changelog/.
			head -n$((1024*32)) changeLog-$V | sed -r -e 's#\[([0-9]+)\]$#[<a href="https://bugzilla.redhat.com/show_bug.cgi?id=\1">\1</a>]#' -e 's/$/<\br>/' >/var/ftp/pub/kernel-changelog/changeLog-$V.html
		}
		\rm ${nvr}.src.rpm

		vr=${nvr/kernel-/}
		vr=${vr%+*}
		sed -r -n "/\*.*\[${vr}\]/,/^$/{p}" changeLog-$V >changeLog
		sed -n '1p;q' changeLog
		grep '^-' changeLog | sort -k2,2
		echo
	done >>$patch

	echo -e "\n\n#===============================================================================" >>$patch
	echo -e "\n#Generated by cron latestKernelCheck" >>$patch
	echo -e "\n#cur:" >>$patch; cat $f.tmp >>$patch
	echo -e "\n#pre:" >>$patch; cat $f     >>$patch
	mv ${f}.tmp ${f}

	[ $available = 1 ] && {
		sendmail.sh -p '[Notice] ' -f "$from" -t "$mailTo" -c "$mailCc" "$patch" ": new RHEL${V} kernel available"  &>/dev/null
	}
	rm -f $patch

	# send notice to IRC
	for nvr in $newkernel; do
		[[ -z "$nvr" || "$nvr" =~ ^\+\+\+ ]] && continue
		changeUrl=$url

		for chan in "#fs-qe" "#network-qe"; do
			ircmsg.sh -s fs-qe.usersys.redhat.com -p 6667 -n testBot -P rhqerobot:irc.devel.redhat.com -L testBot:testBot -C "$chan" \
			    "${ircBold}${ircRoyalblue}{Notice}${ircPlain} new rhel${V} kernel: $nvr    # $changeUrl"
		done

		# highlight the "fs-qe" related bugs
		vr=${nvr/kernel-/}
		vr=${vr%+*}
		sed -r -n "/\*.*\[${vr}\]/,/^$/{p}" changeLog-$V | \
		    grep "^\- \[fs\]" | sed 's/.*\[\([[:digit:]]\+\)\].*/\1/g;t;d' | sort -u >fsBugs

		for bugid in $(cat fsBugs); do
			ircmsg.sh -s fs-qe.usersys.redhat.com -p 6667 -n testBot -P rhqerobot:irc.devel.redhat.com -L testBot:testBot -C "#fs-qe" \
			    "https://bugzilla.redhat.com/$bugid $(su jiyin --command="bugzilla query --bug_id=$bugid --outputformat='- %{qa_contact} - %{summary}'")"
		done
	done
done

popd  >/dev/null

