/* A C program compiled against ZLibc and run in ring 3 by Nevara. */
#include <stdio.h>
#include <string.h>
#include <stdlib.h>

int main(void) {
    printf("  [zlibc] hello from C in ring 3! %d + %d = %d\n", 2, 40, 2 + 40);

    char *p = malloc(64);
    strcpy(p, "string built with malloc + strcpy");
    printf("  [zlibc] %s (len=%d)\n", p, (int)strlen(p));

    puts("  [zlibc] goodbye from C");
    return 0;
}
