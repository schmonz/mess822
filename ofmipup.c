#include "commands.h"
#include "sig.h"
#include "readwrite.h"
#include "timeoutread.h"
#include "timeoutwrite.h"
#include "stralloc.h"
#include "substdio.h"
#include "env.h"
#include "exit.h"
#include "str.h"
#include "base64.h"
#include "wait.h"
#include "fd.h"
#include "byte.h"
#include "case.h"

void die() { _exit(1); }

int saferead(fd,buf,len) int fd; char *buf; int len;
{
  int r;
  r = timeoutread(1200,fd,buf,len);
  if (r <= 0) die();
  return r;
}

int safewrite(fd,buf,len) int fd; char *buf; int len;
{
  int r;
  r = timeoutwrite(1200,fd,buf,len);
  if (r <= 0) die();
  return r;
}

char ssoutbuf[512];
substdio ssout = SUBSTDIO_FDBUF(safewrite,1,ssoutbuf,sizeof ssoutbuf);

char ssinbuf[1024];
substdio ssin = SUBSTDIO_FDBUF(saferead,0,ssinbuf,sizeof ssinbuf);

void puts(s) char *s;
{
  substdio_puts(&ssout,s);
}
void flush()
{
  substdio_flush(&ssout);
}
/* XXX not exactly "err" when I use it to print regular SMTP responses */
void err(s) char *s;
{
    puts(s);
    puts("\r\n");
    flush();
}

/* XXX make these more like popup's */
void die_usage() { puts("usage: ofmipup hostname checkpassword ofmipd\n"); flush(); die(); }
void die_nomem() { err("451 out of memory (#4.3.0)"); die(); }

int err_input() { err("501 malformed auth input (#5.5.4)"); return -1; }
int err_fork() { err("454 child won't start (#4.3.0)"); return -1; }
int err_pipe() { err("454 unable to open pipe (#4.3.0)"); return -1; }
int err_write() { err("454 unable to write pipe (#4.3.0)"); return -1; }
int err_checkpassword_misused() { err("454 checkpassword misused XXX"); return -1; }
int err_checkpassword_tempfail() { err("454 temporary checkpassword failure (#4.3.0)"); return -1; }
int err_checkpassword_unacceptable() { err("535 authorization failed (#5.7.0)"); return 1; }
int err_or_maybe_no_big_deal_ofmipd_nonzero_exit() { return 0; }
int err_child() { err("454 problem with child (#4.3.0)"); return -1; }
int err_authabrt() { err("501 auth exchange cancelled (#5.0.0)"); return -1; }
int err_noauth() { err("504 auth type unimplemented (#5.5.1)"); return -1; }

void err_authoriz() { err("530 Authentication required (#5.7.1)"); }

void smtp_help() { err("214 ofmipup home page: https://schmonz.com/ofmipup/"); }
void smtp_noop() { err("250 ok"); }
void smtp_unimpl() { err("502 unimplemented (#5.5.1)"); }

static stralloc authin = {0};
static stralloc user = {0};
static stralloc pass = {0};
static stralloc resp = {0};
static stralloc slop = {0};
char *hostname;
char **childargs;
substdio ssup;
char upbuf[128];

void smtp_helo(arg) char *arg;
{
  puts("250 ");
  puts(hostname);
  puts("\r\n");
}

void smtp_ehlo(arg) char *arg;
{
  puts("250-");
  puts(hostname);
  puts("\r\n250-AUTH LOGIN PLAIN");
  puts("\r\n250-AUTH=LOGIN PLAIN");
  puts("\r\n250-PIPELINING\r\n250 8BITMIME\r\n");
}

int authgetl(void) {
  int i;

  if (!stralloc_copys(&authin, "")) die_nomem();

  for (;;) {
    if (!stralloc_readyplus(&authin,1)) die_nomem(); /* XXX */
    i = substdio_get(&ssin,authin.s + authin.len,1);
    if (i != 1) die();
    if (authin.s[authin.len] == '\n') break;
    ++authin.len;
  }

  if (authin.len > 0) if (authin.s[authin.len - 1] == '\r') --authin.len;
  authin.s[authin.len] = 0;

  if (*authin.s == '*' && *(authin.s + 1) == 0) { return err_authabrt(); }
  if (authin.len == 0) { return err_input(); }
  return authin.len;
}

int authenticate(void)
{
  int child;
  int wstat;
  int pi[2];
  int exitcode;

  if (!stralloc_0(&user)) die_nomem();
  if (!stralloc_0(&pass)) die_nomem();
  if (!stralloc_0(&resp)) die_nomem();

  if (fd_copy(2,1) == -1) return err_pipe();
  close(3);
  if (pipe(pi) == -1) return err_pipe();
  if (pi[0] != 3) return err_pipe();
  switch(child = fork()) {
    case -1:
      return err_fork();
    case 0: /* XXX child here */
      close(pi[1]);
      sig_pipedefault();
      if (!env_put2("OFMIPUP","")) die_nomem();
      execvp(*childargs, childargs);
      _exit(1);
  }
  close(pi[0]);
  substdio_fdbuf(&ssup,write,pi[1],upbuf,sizeof upbuf);
  if (substdio_put(&ssup,user.s,user.len) == -1) return err_write();
  if (substdio_put(&ssup,pass.s,pass.len) == -1) return err_write();
  if (substdio_put(&ssup,resp.s,resp.len) == -1) return err_write();
  if (substdio_flush(&ssup) == -1) return err_write();
  close(pi[1]);
  byte_zero(pass.s,pass.len);
  byte_zero(upbuf,sizeof upbuf);
  if (wait_pid(&wstat,child) == -1) { err("wait_pid"); return err_child(); }
  if (wait_crashed(wstat)) { err("wait_crashed"); return err_child(); }
  switch(exitcode = wait_exitcode(wstat)) {
    case 0: /* checkpassword succeeded, ofmipd QUIT, happy session over */
      _exit(0);
    case 1: /* checkpassword says username/password no good */
      return err_checkpassword_unacceptable();
    case 2: /* checkpassword invoked incorrectly */
      return err_checkpassword_misused();
    case 3: /* ofmipd returned nonzero */
      return err_or_maybe_no_big_deal_ofmipd_nonzero_exit();
    case 111: /* checkpassword temporary problem */
      return err_checkpassword_tempfail();
    default:
      err("XXX unknown nonzero");
      return err_child(); /* XXX unknown nonzero */
  }
}

int auth_login(arg) char *arg;
{
  int r;

  if (*arg) {
    if ((r = b64decode(arg,str_len(arg),&user)) == 1) return err_input();
  }
  else {
    err("334 VXNlcm5hbWU6"); /* Username: */
    if (authgetl() < 0) return -1;
    if ((r = b64decode(authin.s,authin.len,&user)) == 1) return err_input();
  }
  if (r == -1) die_nomem();

  err("334 UGFzc3dvcmQ6"); /* Password: */

  if (authgetl() < 0) return -1;
  if ((r = b64decode(authin.s,authin.len,&pass)) == 1) return err_input();
  if (r == -1) die_nomem();

  if (!user.len || !pass.len) return err_input();
  return authenticate();
}

int auth_plain(arg) char *arg;
{
  int r, id = 0;

  if (*arg) {
    if ((r = b64decode(arg,str_len(arg),&slop)) == 1) return err_input();
  }
  else {
    err("334 ");
    if (authgetl() < 0) return -1;
    if ((r = b64decode(authin.s,authin.len,&slop)) == 1) return err_input();
  }
  if (r == -1 || !stralloc_0(&slop)) die_nomem();
  while (slop.s[id]) id++; /* ignore authorize-id */

  if (slop.len > id + 1)
    if (!stralloc_copys(&user,slop.s + id + 1)) die_nomem();
  if (slop.len > id + user.len + 2)
    if (!stralloc_copys(&pass,slop.s + id + user.len + 2)) die_nomem();

  if (!user.len || !pass.len) return err_input();
  return authenticate();
}

struct authcmd {
  char *text;
  int (*fun)();
} authcmds[] = {
  { "login", auth_login }
, { "plain", auth_plain }
, { 0, err_noauth }
};

void smtp_auth(arg)
char *arg;
{
  int i;
  char *cmd = arg;

  if (!stralloc_copys(&user,"")) die_nomem();
  if (!stralloc_copys(&pass,"")) die_nomem();
  if (!stralloc_copys(&resp,"")) die_nomem();

  i = str_chr(cmd,' ');
  arg = cmd + i;
  while (*arg == ' ') ++arg;
  cmd[i] = 0;

  /* XXX can this use commands.h too? */
  for (i = 0;authcmds[i].text;++i)
    if (case_equals(authcmds[i].text,cmd)) break;

  switch (authcmds[i].fun(arg)) {
    case 0: /* auth succeeded */
      break;
    case 1: /* auth failed */
      break;
  }
}

void smtp_greet()
{
  puts("220 ");
  puts(hostname);
  puts(" ESMTP\r\n");
  flush();
}

void smtp_quit() {
  puts("221 ");
  puts(hostname);
  puts("\r\n");
  flush();
  die();
}

struct commands smtpcommands[] = {
  { "rcpt", err_authoriz, flush }
, { "mail", err_authoriz, flush }
, { "data", err_authoriz, flush }
, { "auth", smtp_auth, flush }
, { "quit", smtp_quit, flush }
, { "helo", smtp_helo, flush }
, { "ehlo", smtp_ehlo, flush }
, { "rset", err_authoriz, flush }
, { "help", smtp_help, flush }
, { "noop", smtp_noop, flush }
, { "vrfy", err_authoriz, flush }
, { 0, smtp_unimpl, flush }
} ;

int main(argc,argv)
int argc;
char **argv;
{
  sig_pipeignore();

  hostname = argv[1];
  if (!hostname) die_usage();
  childargs = argv + 2;
  if (!*childargs) die_usage();

  smtp_greet();
  commands(&ssin,&smtpcommands);
  die_nomem();
}
