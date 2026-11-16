/*
 * procargs: print the exact command line and environment of processes on
 * macOS, for durable.lua. ps joins a command line's words with spaces, so an
 * option value such as --system-prompt "Keep replies brief." can't be told
 * apart from separate words; the kernel's copy (KERN_PROCARGS2) keeps them.
 *
 *   procargs PID...
 *
 * prints one JSON object per line for each process it may read:
 *
 *   {"pid":123,"argv":["claude","--model","sonnet"],"env":["TERM=xterm"]}
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/sysctl.h>

static void json_string(const char *s, const char *end) {
  putchar('"');
  for (; s < end && *s; s++) {
    unsigned char c = (unsigned char)*s;
    if (c == '"' || c == '\\')
      printf("\\%c", c);
    else if (c < 0x20)
      printf("\\u%04x", c);
    else
      putchar(c);
  }
  putchar('"');
}

/* Layout: int argc, the executable path, NUL padding, argc words, then
 * NAME=value words up to an empty one. */
static void show(int pid) {
  int mib[3] = {CTL_KERN, KERN_PROCARGS2, pid};
  size_t size = 0;
  if (sysctl(mib, 3, NULL, &size, NULL, 0) < 0 || size < sizeof(int)) return;
  char *buf = malloc(size);
  if (!buf) return;
  if (sysctl(mib, 3, buf, &size, NULL, 0) < 0 || size < sizeof(int)) {
    free(buf);
    return;
  }
  int argc;
  memcpy(&argc, buf, sizeof argc);
  char *p = buf + sizeof argc, *end = buf + size;
  while (p < end && *p) p++;
  while (p < end && !*p) p++;
  printf("{\"pid\":%d,\"argv\":[", pid);
  for (int i = 0; i < argc && p < end; i++) {
    if (i) putchar(',');
    json_string(p, end);
    p += strnlen(p, (size_t)(end - p)) + 1;
  }
  printf("],\"env\":[");
  for (int first = 1; p < end && *p; first = 0) {
    if (!first) putchar(',');
    json_string(p, end);
    p += strnlen(p, (size_t)(end - p)) + 1;
  }
  printf("]}\n");
  free(buf);
}

int main(int argc, char **argv) {
  for (int i = 1; i < argc; i++) show(atoi(argv[i]));
  return 0;
}
