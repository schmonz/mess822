#include "error.h"
#include "strerr.h"

struct strerr strerr_sys = {0,0,0,0};

void strerr_sysinit()
{
  strerr_sys.who = 0;
  strerr_sys.x = error_str(errno);
  strerr_sys.y = "";
  strerr_sys.z = "";
}
