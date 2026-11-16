/*
 * A stand-in for fx, Claude Code, or Codex in the end-to-end test. It keeps
 * its conversation's file the way the real program does, then waits:
 *
 *   fx      holds FAKE_HOME/.fx/sessions/v2/<id>/lock open
 *   codex   holds FAKE_HOME/.codex/sessions/.../rollout-<time>-<id>.jsonl open
 *   claude  writes FAKE_HOME/.claude/projects/<folder>/<id>.jsonl and closes it,
 *           and FAKE_HOME/.claude/sessions/<pid>.json unless FAKE_NO_RECORD is set
 *
 * Built by test/e2e.sh with -DAPP="fx" (or claude, codex) and -DFAKE_HOME.
 */
#include <ctype.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

static void make_dirs(const char *path) {
  char buf[4096];
  snprintf(buf, sizeof buf, "%s", path);
  for (char *p = buf + 1; *p; p++) {
    if (*p == '/') {
      *p = 0;
      mkdir(buf, 0755);
      *p = '/';
    }
  }
  mkdir(buf, 0755);
}

int main(int argc, char **argv) {
  const char *app = APP;
  char id[128] = "";
  for (int i = 1; i < argc; i++) {
    if (!strcmp(argv[i], "--help")) {
      printf("usage: %s [-r, --resume [last|<id>]]\n", app);
      return 0;
    }
    if ((!strcmp(argv[i], "--resume") || !strcmp(argv[i], "-r")) && i + 1 < argc)
      snprintf(id, sizeof id, "%s", argv[++i]);
    else if (!strcmp(argv[i], "resume") && i + 1 < argc)
      snprintf(id, sizeof id, "%s", argv[argc - 1]);
  }
  if (!id[0]) {
    if (!strcmp(app, "fx"))
      snprintf(id, sizeof id, "new%d", (int)getpid());
    else
      snprintf(id, sizeof id, "00000000-0000-4000-8000-%012d", (int)getpid());
  }

  char cwd[2048], dir[4096], file[4608];
  if (!getcwd(cwd, sizeof cwd)) return 1;
  int keep_open = 1;
  if (!strcmp(app, "fx")) {
    snprintf(dir, sizeof dir, "%s/.fx/sessions/v2/%s", FAKE_HOME, id);
    snprintf(file, sizeof file, "%s/lock", dir);
  } else if (!strcmp(app, "codex")) {
    snprintf(dir, sizeof dir, "%s/.codex/sessions/2026/11/13", FAKE_HOME);
    snprintf(file, sizeof file, "%s/rollout-2026-11-13T10-00-00-%s.jsonl", dir, id);
  } else {
    char slug[2048];
    snprintf(slug, sizeof slug, "%s", cwd);
    for (char *p = slug; *p; p++)
      if (!isalnum((unsigned char)*p)) *p = '-';
    snprintf(dir, sizeof dir, "%s/.claude/projects/%s", FAKE_HOME, slug);
    snprintf(file, sizeof file, "%s/%s.jsonl", dir, id);
    keep_open = 0;
  }
  make_dirs(dir);
  int fd = open(file, O_WRONLY | O_CREAT | O_APPEND, 0644);
  if (fd < 0) {
    perror(file);
    return 1;
  }
  char line[4096];
  int n = snprintf(line, sizeof line,
                   "{\"type\":\"session_meta\",\"payload\":{\"id\":\"%s\",\"cwd\":\"%s\"}}\n", id, cwd);
  if (write(fd, line, (size_t)n) != n) return 1;
  if (!keep_open) close(fd);
  if (!strcmp(app, "claude") && !getenv("FAKE_NO_RECORD")) {
    snprintf(dir, sizeof dir, "%s/.claude/sessions", FAKE_HOME);
    make_dirs(dir);
    snprintf(file, sizeof file, "%s/%d.json", dir, (int)getpid());
    FILE *record = fopen(file, "w");
    if (!record) return 1;
    fprintf(record, "{\"pid\":%d,\"sessionId\":\"%s\",\"cwd\":\"%s\"}\n", (int)getpid(), id, cwd);
    fclose(record);
  }
  printf("fake %s on %s\n", app, id);
  fflush(stdout);
  for (;;) pause();
}
