// One translated header for everything the Zig build calls in C: SQLite plus
// the few libc calls Zig std does not wrap (local time, symlinks).
#include "sqlite3.h"
#include <time.h>
#include <unistd.h>
#include <stdlib.h>
#include <fcntl.h>
#include <stdint.h>
