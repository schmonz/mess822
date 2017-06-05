#!/bin/sh

OFMIPD=./ofmipd
CONF_QMAIL=$(pwd)/tmp
CONF_CC="gcc -O2 -include /usr/include/errno.h"

bail_on_any_nonzero_exit_code() {
	set -e
}

show_commands_being_run() {
	set -x
}

make_clean() {
	local _file

	rm -rf "${CONF_QMAIL}"
	rm -f `cat TARGETS`
	git checkout -- INSTALL conf-cc conf-qmail strerr_sys.c

	_file=ofmipd.c
	if grep -q 'include/sleep.h' ${_file}; then
		sed -e '/^\#include "tmp\/include\/sleep.h"$/d' < ${_file} > ${_file}.new
		mv ${_file}.new ${_file}
	fi

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
	_file=ofmipd.c
	if ! grep -q 'include/sleep.h' ${_file}; then
		(
			echo '#include "tmp/include/sleep.h"'
			cat ${_file}
		) > ${_file}.new
		mv ${_file}.new ${_file}
	fi
}

set_fakes_for_test() {
	mkdir -p "${CONF_QMAIL}/bin" "${CONF_QMAIL}/include"
	[ "/var/qmail" = "`head -1 conf-qmail`" ] && echo "${CONF_QMAIL}" > conf-qmail || true

	echo "#!/bin/sh\nexit 0" > "${CONF_QMAIL}/bin/qmail-queue"
	chmod +x "${CONF_QMAIL}/bin/qmail-queue"

	echo '#!/bin/sh\nif [ "yes" = "${OFMIPD_CHECKPASSWORD_SHOULD_SUCCEED}" ]; then exec "$@"; else exit 1; fi' > ${CONF_QMAIL}/bin/checkpassword
	chmod +x "${CONF_QMAIL}/bin/checkpassword"

	if [ ! -f "${CONF_QMAIL}/include/sleep.h" ]; then
		echo 'unsigned int sleep(unsigned int seconds) { return; }' >> ${CONF_QMAIL}/include/sleep.h
	fi
}

build_ofmipd() {
	make ofmipd >/dev/null 2>&1
}

test_ofmipd() {
	test_verb \
		"" \
		""

	test_verb \
		"EXPN so-and-so" \
		"502 unimplemented (#5.5.1)"

	test_verb \
		"HELO" \
		"250 ofmipd.local"

	test_verb \
		"EHLO" \
		"250-ofmipd.local\n250-AUTH LOGIN PLAIN\n250-AUTH=LOGIN PLAIN\n250-PIPELINING\n250 8BITMIME"

	test_verb \
		"RSET" \
		"250 flushed"

	test_norelayclient_verb_unauthorized \
		"MAIL SCHMONZ: <one@two.three>"
	test_relayclient_verb \
		"MAIL SCHMONZ: <one@two.three>" \
		"250 ok"

	test_norelayclient_verb_unauthorized \
		"RCPT SCHMONZ: <four@five.six>"
	test_relayclient_verb \
		"RCPT SCHMONZ: <four@five.six>" \
		"503 MAIL first (#5.5.1)"

	test_relayclient_verb \
		"MAIL SCHMONZ: <one@two.three>" \
		"250 ok" \
		"RCPT SCHMONZ: <four@five.six>" \
		"250 ok"

	test_norelayclient_verb_unauthorized \
		"DATA"
	test_relayclient_verb \
		"DATA" \
		"503 MAIL first (#5.5.1)"
	test_relayclient_verb \
		"MAIL me: one" \
		"250 ok" \
		"DATA" \
		"503 RCPT first (#5.5.1)"
	test_relayclient_verb \
		"MAIL me: one" \
		"250 ok" \
		"RCPT you: two" \
		"250 ok" \
		"DATA" \
		"354 go ahead" \
		"don't mind if I do.\nI got lots to say.\n." \
		"250 ok"

	test_verb \
		"QUIT" \
		"221 ofmipd.local"
	test_relayclient_verb \
		"MAIL me: one" \
		"250 ok" \
		"QUIT" \
		"221 ofmipd.local"

	test_verb \
		"HELP" \
		"214 qmail home page: http://pobox.com/~djb/qmail.html"
	test_relayclient_verb \
		"mail me: one" \
		"250 ok" \
		"help me please" \
		"214 qmail home page: http://pobox.com/~djb/qmail.html"

	test_verb \
		"NOOP" \
		"250 ok"
	test_relayclient_verb \
		"mail me: one" \
		"250 ok" \
		"noop whatever else" \
		"250 ok"

	test_verb \
		"VRFY so-and-so" \
		"252 send some mail, i'll try my best"

	test_auth_verbs
}

test_auth_verbs() {
	local _plain _loginuser _loginpass
	REGULAR_UNAUTH_OFMIPD="${OFMIPD}"
	export OFMIPD_CHECKPASSWORD_SHOULD_SUCCEED

	OFMIPD="${OFMIPD} /dev/null very-hostname-so-wow ${CONF_QMAIL}/bin/checkpassword true"

	test_verb \
		"AUTH" \
		"504 auth type unimplemented (#5.5.1)"
	test_verb \
		"AUTH FLOOF" \
		"504 auth type unimplemented (#5.5.1)"


	_plain=$(printf "%s\0%s\0%s" fakeuser fakeuser fakepass | base64)
	OFMIPD_CHECKPASSWORD_SHOULD_SUCCEED=no
	test_verb \
		"AUTH PLAIN ${_plain}" \
		"535 authorization failed (#5.7.0)"
	OFMIPD_CHECKPASSWORD_SHOULD_SUCCEED=yes
	test_verb \
		"AUTH PLAIN" \
		"334 "
	test_verb \
		"AUTH PLAIN ${_plain}" \
		"235 ok, go ahead (#2.0.0)"

	_loginuser=$(printf "%s" fakeuser | base64)
	_loginpass=$(printf "%s" fakepass | base64)
	OFMIPD_CHECKPASSWORD_SHOULD_SUCCEED=no
	test_verb \
		"AUTH LOGIN" \
		"334 VXNlcm5hbWU6" \
		"${_loginuser}" \
		"334 UGFzc3dvcmQ6" \
		"${_loginpass}" \
		"535 authorization failed (#5.7.0)" \
		"DATA" \
		"503 authorize or check your mail before sending (#5.5.1)"
	OFMIPD_CHECKPASSWORD_SHOULD_SUCCEED=yes
	test_verb \
		"AUTH LOGIN" \
		"334 VXNlcm5hbWU6" \
		"${_loginuser}" \
		"334 UGFzc3dvcmQ6" \
		"${_loginpass}" \
		"235 ok, go ahead (#2.0.0)" \
		"DATA" \
		"503 MAIL first (#5.5.1)"

	unset OFMIPD_CHECKPASSWORD_SHOULD_SUCCEED

	OFMIPD="${REGULAR_UNAUTH_OFMIPD}"
}

test_norelayclient_verb_unauthorized() {
	test_verb \
		"$1" \
		"503 authorize or check your mail before sending (#5.5.1)"
}

test_relayclient_verb() {
	RELAYCLIENT=""
	export RELAYCLIENT
	test_verb "$@"
	unset RELAYCLIENT
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
		_actual=$(${OFMIPD} < /dev/null) || true
	else
		_actual=$(echo "${_actual}" | ${OFMIPD}) || true
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
	configure_sleep_workaround
	set_fakes_for_test
	build_ofmipd
	test_ofmipd
}

main "$@"
exit $?
