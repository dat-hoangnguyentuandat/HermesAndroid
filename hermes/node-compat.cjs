// The glibc loader is /proc/self/exe on Android. Child Node processes must
// re-enter our loader wrapper, not execute that loader with Node arguments.
if (process.env.HERMES_NODE) process.execPath = process.env.HERMES_NODE;
