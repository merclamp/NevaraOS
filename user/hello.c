/* hello.c — ZLibc smoke test, compiled against ZLibc and run in ring 3. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <ctype.h>

static int passed = 0;
static int failed = 0;

#define CHECK(cond, msg) do { \
    if (cond) { printf("[OK] %s\n", msg); passed++; } \
    else       { printf("[FAIL] %s\n", msg); failed++; } \
} while (0)

int main(void) {
    printf("=== ZLibc smoke test ===\n");

    /* ---- string.h ---- */
    CHECK(strlen("hello") == 5,       "strlen");
    CHECK(strnlen("hello", 3) == 3,   "strnlen");

    char buf[64];
    strcpy(buf, "world");
    CHECK(strcmp(buf, "world") == 0,   "strcpy/strcmp");

    strncpy(buf, "abcdef", 3); buf[3] = '\0';
    CHECK(strcmp(buf, "abc") == 0,     "strncpy");

    strcpy(buf, "hello");
    strcat(buf, " world");
    CHECK(strcmp(buf, "hello world") == 0, "strcat");

    strcpy(buf, "hello");
    strncat(buf, "!!!!", 2);
    CHECK(strcmp(buf, "hello!!") == 0,  "strncat");

    CHECK(strncmp("abc", "abd", 2) == 0, "strncmp equal prefix");
    CHECK(strncmp("abc", "abd", 3) != 0, "strncmp differ");

    CHECK(strcasecmp("Hello", "hello") == 0, "strcasecmp");

    strcpy(buf, "find me here");
    CHECK(strchr(buf, 'm') == buf + 5,  "strchr");
    CHECK(strrchr(buf, 'e') == buf + 12, "strrchr");
    CHECK(strstr(buf, "me") == buf + 5, "strstr");

    memset(buf, 'Z', 4); buf[4] = '\0';
    CHECK(strcmp(buf, "ZZZZ") == 0,    "memset");

    char src[8] = "overlap";
    memmove(src + 2, src, 5);
    CHECK(src[2] == 'o',               "memmove");

    CHECK(memcmp("abc", "abc", 3) == 0, "memcmp eq");
    CHECK(memcmp("abc", "abd", 3) < 0,  "memcmp lt");

    char *dup = strdup("duptest");
    CHECK(dup != NULL && strcmp(dup, "duptest") == 0, "strdup");
    free(dup);

    char tok_src[] = "one two three";
    char *t = strtok(tok_src, " ");
    CHECK(t != NULL && strcmp(t, "one") == 0, "strtok first");
    t = strtok(NULL, " ");
    CHECK(t != NULL && strcmp(t, "two") == 0, "strtok next");

    /* ---- stdlib.h ---- */
    CHECK(atoi("42") == 42,             "atoi");
    CHECK(atoi("-7") == -7,             "atoi negative");
    CHECK(atol("123456") == 123456L,    "atol");

    char *end;
    CHECK(strtol("0xFF", &end, 16) == 255, "strtol hex");
    CHECK(strtol("010", &end, 8)  == 8,    "strtol octal");
    CHECK(strtol("0x1A", &end, 0) == 26,   "strtol auto base");

    CHECK(abs(-5) == 5,                 "abs");
    CHECK(labs(-999L) == 999L,          "labs");

    void *p = calloc(4, 2);
    CHECK(p != NULL,                    "calloc");
    unsigned char *cp = (unsigned char *)p;
    int zeroed = 1;
    for (int i = 0; i < 8; i++) if (cp[i] != 0) { zeroed = 0; break; }
    CHECK(zeroed,                       "calloc zeroed");
    free(p);

    /* ---- ctype.h ---- */
    CHECK(isdigit('5') && !isdigit('a'), "isdigit");
    CHECK(isalpha('x') && !isalpha('1'), "isalpha");
    CHECK(isalnum('a') && isalnum('9'),  "isalnum");
    CHECK(isspace(' ') && isspace('\n'), "isspace");
    CHECK(isupper('A') && !isupper('a'), "isupper");
    CHECK(islower('z') && !islower('Z'), "islower");
    CHECK(toupper('a') == 'A',           "toupper");
    CHECK(tolower('Z') == 'z',           "tolower");

    /* ---- stdio.h: sprintf / snprintf / sscanf ---- */
    snprintf(buf, sizeof(buf), "num=%d hex=0x%x str=%s", 42, 255, "hi");
    CHECK(strcmp(buf, "num=42 hex=0xff str=hi") == 0, "snprintf");

    sprintf(buf, "%05d", 7);
    CHECK(strcmp(buf, "00007") == 0,    "sprintf zero-pad");

    sprintf(buf, "%-6s!", "left");
    CHECK(strcmp(buf, "left  !") == 0,  "sprintf left-align");

    sprintf(buf, "%+d %+d", 3, -3);
    CHECK(strcmp(buf, "+3 -3") == 0,    "sprintf sign");

    int n;
    unsigned x;
    char s2[32];
    int r = sscanf("42 0xff hello", "%d %x %s", &n, &x, s2);
    CHECK(r == 3 && n == 42 && x == 255 && strcmp(s2, "hello") == 0, "sscanf");

    /* ---- Summary ---- */
    printf("=== %d passed, %d failed ===\n", passed, failed);
    return failed > 0 ? 1 : 0;
}
