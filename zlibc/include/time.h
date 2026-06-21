#ifndef _TIME_H
#define _TIME_H

typedef long time_t;
typedef long clock_t;
typedef unsigned long size_t;

#define CLOCKS_PER_SEC 100   /* PIT at 100 Hz; pit.jiffies is the tick source */

struct tm {
    int tm_sec;    /* 0-60  */
    int tm_min;    /* 0-59  */
    int tm_hour;   /* 0-23  */
    int tm_mday;   /* 1-31  */
    int tm_mon;    /* 0-11  */
    int tm_year;   /* years since 1900 */
    int tm_wday;   /* 0-6, Sunday=0 */
    int tm_yday;   /* 0-365 */
    int tm_isdst;  /* DST flag */
};

/* Seconds since boot (epoch = 0; no RTC in this phase). */
time_t time(time_t *tloc);

/* Processor ticks since boot (= pit.jiffies). */
clock_t clock(void);

double difftime(time_t t1, time_t t0);

/* Both functions treat epoch as 1970-01-01 00:00:00 UTC + seconds-since-boot. */
struct tm *gmtime(const time_t *timer);
struct tm *localtime(const time_t *timer);

time_t mktime(struct tm *tm);

/* Format time into buf (strftime subset: %Y %m %d %H %M %S %c %s). */
size_t strftime(char *buf, size_t max, const char *fmt, const struct tm *tm);

#endif /* _TIME_H */
