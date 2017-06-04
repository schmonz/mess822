#!/bin/sh

CONF_QMAIL=/var/tmp/varqmail
CONF_CC="gcc -O2 -include /usr/include/errno.h"

bail_on_any_nonzero_exit_code() {
	set -e
}

show_commands_being_run() {
	set -x
}

make_clean() {
	rm -f `cat TARGETS`
	git co -- INSTALL conf-cc conf-qmail strerr_sys.c
	exit 0
}

configure_errno_workaround() {
	[ "gcc -O2" = "`head -1 conf-cc`" ] && echo "${CONF_CC}" > conf-cc || true
}

configure_strerr_sys_workaround() {
	sed -e 's|^struct strerr strerr_sys;$|struct strerr strerr_sys = {0,0,0,0};|g' < strerr_sys.c > strerr_sys.c.new && mv strerr_sys.c.new strerr_sys.c
}

set_fake_paths_for_test() {
	mkdir -p ${CONF_QMAIL}
	[ "/var/qmail" = "`head -1 conf-qmail`" ] && echo "${CONF_QMAIL}" > conf-qmail || true
}

build_ofmipd() {
	make ofmipd >/dev/null 2>&1
}

test_ofmipd() {
	test_verb \
		"" \
		""
	test_verb \
		"SCHMONZ" \
		"502 unimplemented (#5.5.1)"
	test_verb \
		"HELO" \
		"250 ofmipd.local"
	test_verb \
		"EHLO" \
		"250-ofmipd.local\n250-PIPELINING\n250 8BITMIME"
	test_verb \
		"RSET" \
		"250 flushed"
	test_verb \
		"MAIL SCHMONZ: <one@two.three>" \
		"250 ok"
	test_verb \
		"RCPT SCHMONZ: <four@five.six>" \
		"503 MAIL first (#5.5.1)"
	test_verb \
		"MAIL SCHMONZ: <one@two.three>" \
		"250 ok" \
		"RCPT SCHMONZ: <four@five.six>" \
		"250 ok"

	# XXX DATA
	# XXX QUIT
	# XXX HELP
	# XXX NOOP
	# XXX VRFY
	# XXX lowercase verbs
	# XXX MAIL with and without FROM:
	# XXX MAIL FROM: with and without <>
}

test_verb() {
	local _banner _expected _actual
	_banner="220 ofmipd.local ESMTP"
	_expected="${_banner}"
	_actual=""

	while [ $# -ge 2 ]; do
		[ -n "$2" ] && _expected="${_expected}\n$2"
		if [ -z "${_actual}" ]; then
			_actual="$1"
		else
			_actual="${_actual}\n$1"
		fi
		shift; shift
	done

	_expected=$(echo "${_expected}" | sed -e 's|$||g')

	if [ -z "${_actual}" ]; then
		_actual=$(./ofmipd < /dev/null) || true
	else
		_actual=$(echo "${_actual}" | ./ofmipd) || true
	fi

	strings_equal "${_expected}" "${_actual}"
}

strings_equal() {
	if [ "${_expected}" != "${_actual}" ]; then
		echo "=> Expected: ${_expected}" | cat -v
		echo "=>   Actual: ${_actual}"   | cat -v
	fi
}

main() {
	bail_on_any_nonzero_exit_code
	[ "clean" = "$1" ] && make_clean
	[ "verbose" = "$1" ] && show_commands_being_run
	configure_errno_workaround
	configure_strerr_sys_workaround
	set_fake_paths_for_test
	build_ofmipd
	test_ofmipd
}

main "$@"
exit $?
