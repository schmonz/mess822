#include "cdbmss.h"
#include "strerr.h"
#include "open.h"
#include "substdio.h"
#include "subfd.h"
#include "stralloc.h"
#include "getln.h"
#include "exit.h"

#define FATAL "ofmipname: fatal: "

char *fncdb;
char *fntmp;

void nomem()
{ strerr_die2x(111,FATAL,"out of memory"); }
void die_read()
{ strerr_die2sys(111,FATAL,"unable to read input: "); }
void die_write()
{ strerr_die4sys(111,FATAL,"unable to create ",fntmp,": "); }
void usage()
{ strerr_die1x(100,"ofmipname: usage: ofmipname cdb tmp"); }

struct cdbmss cdbmss;

stralloc line = {0};
int match;

stralloc key = {0};
stralloc data = {0};

void doit(x,len)
char *x;
unsigned int len;
{
  unsigned int colon;

  if (!len) return;
  if (x[0] == '#') return;

  colon = byte_chr(x,len,':');
  if (colon == len) return;
  if (!stralloc_copyb(&key,x,colon)) nomem();
  ++colon; x += colon; len -= colon;

  colon = byte_chr(x,len,':');
  if (colon == len) return;
  if (!stralloc_copyb(&data,x,colon)) nomem();
  if (!stralloc_0(&data)) nomem();
  ++colon; x += colon; len -= colon;

  colon = byte_chr(x,len,':');
  if (colon == len) return;
  if (!stralloc_catb(&data,x,colon)) nomem();
  ++colon; x += colon; len -= colon;

  if (cdbmss_add(&cdbmss,key.s,key.len,data.s,data.len) == -1)
    die_write();
}

void main(argc,argv)
int argc;
char **argv;
{
  int fd;

  umask(033);

  fncdb = argv[1];
  if (!fncdb) usage();
  fntmp = argv[2];
  if (!fntmp) usage();

  fd = open_trunc(fntmp);
  if (fd == -1) die_write();
  if (cdbmss_start(&cdbmss,fd) == -1) die_write();

  for (;;) {
    if (getln(subfdin,&line,&match,'\n') == -1) die_read();
    doit(line.s,line.len);
    if (!match) break;
  }

  if (cdbmss_finish(&cdbmss) == -1) die_write();
  if (fsync(fd) == -1) die_write();
  if (close(fd) == -1) die_write(); /* NFS stupidity */
  if (rename(fntmp,fncdb) == -1)
    strerr_die5sys(111,FATAL,"unable to move ",fntmp," to ",fncdb);

  _exit(0);
}
