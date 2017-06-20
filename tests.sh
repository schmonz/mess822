#!/bin/sh

REGULAR_UNAUTH_OFMIPD="./ofmipd"
OFMIPD="${REGULAR_UNAUTH_OFMIPD}"
PARENT_HOSTNAME="ofmipup.local"
CHILD_HOSTNAME="ofmipd.local"
CONF_QMAIL=$(pwd)/tmp
CONF_CC="gcc -O2 -include /usr/include/errno.h"

bail_on_any_nonzero_exit_code() {
	set -e
}

show_commands_being_run() {
	set -x
}

make_clean() {
	rm -rf "${CONF_QMAIL}"
	rm -f `cat TARGETS`
	git checkout -- INSTALL conf-cc conf-qmail strerr_sys.c
	unconfigure_sleep_workaround
	exit 0
}

configure_errno_workaround() {
	[ "gcc -O2" = "`head -1 conf-cc`" ] && echo "${CONF_CC}" > conf-cc || true
}

configure_strerr_sys_workaround() {
	local _file
	_file=strerr_sys.c
	if ! grep -q '{0,0,0,0}' ${_file}; then
		sed -e 's|^struct strerr strerr_sys;$|struct strerr strerr_sys = {0,0,0,0};|g' < ${_file} > ${_file}.new
		mv ${_file}.new ${_file}
	fi
}

configure_sleep_workaround() {
	local _file
	_file=ofmipup.c
	if ! grep -q 'include/sleep.h' ${_file}; then
		(
			echo '#include "tmp/include/sleep.h"'
			cat ${_file}
		) > ${_file}.new
		mv ${_file}.new ${_file}
	fi
}

unconfigure_sleep_workaround() {
	local _file
	_file=ofmipup.c
	if grep -q 'tmp/include/sleep.h' ${_file}; then
		sed -e '/^\#include "tmp\/include\/sleep.h"$/d' < ${_file} > ${_file}.new
		mv ${_file}.new ${_file}
	fi
}

set_fakes_for_test() {
	mkdir -p "${CONF_QMAIL}/bin" "${CONF_QMAIL}/include" "${CONF_QMAIL}/log"
	[ "/var/qmail" = "`head -1 conf-qmail`" ] && echo "${CONF_QMAIL}" > conf-qmail || true

	echo >"${CONF_QMAIL}/bin/log-and-reject" \
'#!/bin/sh
tee '"${CONF_QMAIL}/log/message"'
exit 31'
	chmod +x "${CONF_QMAIL}/bin/log-and-reject"

	echo >"${CONF_QMAIL}/bin/qmail-queue" \
'#!/bin/sh
qmail-qfilter '"${CONF_QMAIL}/bin/log-and-reject"
	chmod +x "${CONF_QMAIL}/bin/qmail-queue"

	echo >"${CONF_QMAIL}/bin/checkpassword-succeeds" \
'#!/bin/sh
exec "$@"'
	chmod +x "${CONF_QMAIL}/bin/checkpassword-succeeds"

	echo >"${CONF_QMAIL}/bin/checkpassword-fails" \
'#!/bin/sh
exit 1'
	chmod +x "${CONF_QMAIL}/bin/checkpassword-fails"

	if [ ! -f "${CONF_QMAIL}/include/sleep.h" ]; then
		echo 'unsigned int sleep(unsigned int seconds) { return 0; }' >> ${CONF_QMAIL}/include/sleep.h
	fi
}

build_ofmipd() {
	make ofmipd ofmipup >/dev/null 2>&1
}

test_ofmipd() {
	test_unauth_verbs
	test_auth_verbs
}

test_unauth_verbs() {
	test_verb \
		"it sends the banner" \
		"${CHILD_HOSTNAME}" \
		"" \
		""

	test_verb \
		"it doesn't know about EXPN" \
		"${CHILD_HOSTNAME}" \
		"EXPN so-and-so" \
		"502 unimplemented (#5.5.1)"

	test_verb \
		"it knows about HELO" \
		"${CHILD_HOSTNAME}" \
		"HELO" \
		"250 ${CHILD_HOSTNAME}"

	test_verb \
		"it knows about EHLO" \
		"${CHILD_HOSTNAME}" \
		"EHLO" \
		"250-${CHILD_HOSTNAME}"'
250-PIPELINING
250 8BITMIME'

	test_verb \
		"it knows about RSET" \
		"${CHILD_HOSTNAME}" \
		"RSET" \
		"250 flushed"

	test_verb \
		"it knows about MAIL" \
		"${CHILD_HOSTNAME}" \
		"MAIL SCHMONZ: <one@two.three>" \
		"250 ok"

	test_verb \
		"it rejects RCPT when it doesn't follow MAIL" \
		"${CHILD_HOSTNAME}" \
		"RCPT SCHMONZ: <four@five.six>" \
		"503 MAIL first (#5.5.1)"

	test_verb \
		"it accepts RCPT when it follows MAIL" \
		"${CHILD_HOSTNAME}" \
		"MAIL SCHMONZ: <one@two.three>" \
		"250 ok" \
		"RCPT SCHMONZ: <four@five.six>" \
		"250 ok"

	test_verb \
		"it rejects DATA when it doesn't follow MAIL" \
		"${CHILD_HOSTNAME}" \
		"DATA" \
		"503 MAIL first (#5.5.1)"
	test_verb \
		"it rejects DATA when it doesn't follow RCPT" \
		"${CHILD_HOSTNAME}" \
		"MAIL me: one" \
		"250 ok" \
		"DATA" \
		"503 RCPT first (#5.5.1)"
	test_verb \
		"it accepts DATA when it follows MAIL and RCPT" \
		"${CHILD_HOSTNAME}" \
		"MAIL me: one" \
		"250 ok" \
		"RCPT you: two" \
		"250 ok" \
		"DATA" \
		"354 go ahead" \
		"don't mind if I do."'
I got lots to say.
.' \
		"554 mail server permanently rejected message (#5.3.0)"

	test_verb \
		"it knows about QUIT" \
		"${CHILD_HOSTNAME}" \
		"QUIT" \
		"221 ${CHILD_HOSTNAME}"
	test_verb \
		"it knows about QUIT in the middle of something" \
		"${CHILD_HOSTNAME}" \
		"MAIL me: one" \
		"250 ok" \
		"QUIT" \
		"221 ${CHILD_HOSTNAME}"

	test_verb \
		"it knows about HELP" \
		"${CHILD_HOSTNAME}" \
		"HELP" \
		"214 qmail home page: http://pobox.com/~djb/qmail.html"
	test_verb \
		"it knows about HELP in the middle of something" \
		"${CHILD_HOSTNAME}" \
		"mail me: one" \
		"250 ok" \
		"help me please" \
		"214 qmail home page: http://pobox.com/~djb/qmail.html"

	test_verb \
		"it knows about NOOP" \
		"${CHILD_HOSTNAME}" \
		"NOOP" \
		"250 ok"
	test_verb \
		"it knows about NOOP in the middle of something" \
		"${CHILD_HOSTNAME}" \
		"mail me: one" \
		"250 ok" \
		"noop whatever else" \
		"250 ok"

	test_verb \
		"it knows about VRFY" \
		"${CHILD_HOSTNAME}" \
		"VRFY so-and-so" \
		"252 send some mail, i'll try my best"
}

test_auth_verbs() {
	local _plain _loginuser _loginpass
	REGULAR_UNAUTH_OFMIPD="${OFMIPD}"

	OFMIPD="./ofmipup ${PARENT_HOSTNAME} ${CONF_QMAIL}/bin/checkpassword-succeeds ${REGULAR_UNAUTH_OFMIPD}"

	test_verb \
		"it knows about EHLO" \
		"${PARENT_HOSTNAME}" \
		"EHLO" \
		"250-${PARENT_HOSTNAME}"'
250-AUTH LOGIN PLAIN
250-AUTH=LOGIN PLAIN
250-PIPELINING
250 8BITMIME'

	test_verb \
		"it knows about AUTH but needs a type" \
		"${PARENT_HOSTNAME}" \
		"AUTH" \
		"504 auth type unimplemented (#5.5.1)"
	test_verb \
		"it knows about AUTH but not about FLOOF" \
		"${PARENT_HOSTNAME}" \
		"AUTH FLOOF" \
		"504 auth type unimplemented (#5.5.1)"


	_plain=$(printf "%s\0%s\0%s" fakeuser fakeuser fakepass | base64)

	OFMIPD="./ofmipup ${PARENT_HOSTNAME} ${CONF_QMAIL}/bin/checkpassword-fails ${REGULAR_UNAUTH_OFMIPD}"
	test_verb \
		"it fails AUTH PLAIN when checkpassword fails" \
		"${PARENT_HOSTNAME}" \
		"AUTH PLAIN ${_plain}" \
		"535 authorization failed (#5.7.0)"

	OFMIPD="./ofmipup ${PARENT_HOSTNAME} ${CONF_QMAIL}/bin/checkpassword-succeeds ${REGULAR_UNAUTH_OFMIPD}"
	test_verb \
		"it sorta tolerates AUTH PLAIN with no args" \
		"${PARENT_HOSTNAME}" \
		"AUTH PLAIN" \
		"334 "
#	test_verb \
#		"it passes AUTH PLAIN when checkpassword succeeds" \
#		"${PARENT_HOSTNAME}" \
#		"AUTH PLAIN ${_plain}" \
#		"235 ok, go ahead (#2.0.0)" \
#		"DATA" \
#		"503 MAIL first (#5.5.1)"
	# everything after "ok, go ahead" should be handled by kid's smtpcommands!
	# maybe parent is the one responding to DATA?
	# or maybe it's the kid (after fork(), but before exec())
	# or something else?
	# if we sleep 1s before sending "DATA", it works right
	# racey race condition XXX
	# 
	# Two things:
	# 1. Make damn sure clients can't possibly talk to parent after AUTH
	# 2. Change test_verb to send a line, wait for response, send another...
	#
	# List of things to do a good job:
	# - checkpassword(1) chdir($HOME) for ofmipd, so where's qmail-queue?

	_loginuser=$(printf "%s" fakeuser | base64)
	_loginpass=$(printf "%s" fakepass | base64)
	OFMIPD="./ofmipup ${PARENT_HOSTNAME} ${CONF_QMAIL}/bin/checkpassword-fails ${REGULAR_UNAUTH_OFMIPD}"
	test_verb \
		"it fails AUTH LOGIN when checkpassword fails" \
		"${PARENT_HOSTNAME}" \
		"AUTH LOGIN" \
		"334 VXNlcm5hbWU6" \
		"${_loginuser}" \
		"334 UGFzc3dvcmQ6" \
		"${_loginpass}" \
		"535 authorization failed (#5.7.0)"
#	OFMIPD="./ofmipup ${PARENT_HOSTNAME} ${CONF_QMAIL}/bin/checkpassword-succeeds ${REGULAR_UNAUTH_OFMIPD}"
#	test_verb \
#		"it passes AUTH LOGIN when checkpassword succeeds" \
#		"${PARENT_HOSTNAME}" \
#		"AUTH LOGIN" \
#		"334 VXNlcm5hbWU6" \
#		"${_loginuser}" \
#		"334 UGFzc3dvcmQ6" \
#		"${_loginpass}" \
#		"235 ok, go ahead (#2.0.0)" \
#		"DATA" \
#		"503 MAIL first (#5.5.1)"

	OFMIPD="${REGULAR_UNAUTH_OFMIPD}"
}

test_verb() {
	local _description _banner _expected _actual
	_description="$1"; shift
	_banner="220 $1 ESMTP"; shift
	_expected="${_banner}"
	_actual=""

	while [ $# -ge 2 ]; do
		[ -n "$2" ] && _expected="${_expected}"'
'"$2"
		if [ -z "${_actual}" ]; then
			_actual="$1"
		else
			_actual="${_actual}"'
'"$1"
		fi
		shift; shift
	done

	_expected=$(echo "${_expected}" | sed -e 's|$||g')

	if [ -z "${_actual}" ]; then
		_actual=$(${OFMIPD} < /dev/null) || true
	else
		_actual=$(echo "${_actual}" | ${OFMIPD}) || true
	fi

	strings_equal "${_description}" "${_expected}" "${_actual}"
}

strings_equal() {
	local _description _expected _actual
	_description="$1"
	_expected="$2"
	_actual="$3"
	if [ "${_expected}" != "${_actual}" ]; then
		echo
		echo "Failed '${_description}'"
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
	configure_sleep_workaround
	set_fakes_for_test
	build_ofmipd
	test_ofmipd
}

main "$@"
exit $?
