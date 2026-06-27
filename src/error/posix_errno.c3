module nova::posix_errno @private;

import libc;

<*
 POSIX errno constants normalized for Linux and macOS.
*>
const Errno E_PERM                            = EPERM;
const Errno E_NOENT                           = ENOENT;
const Errno E_SRCH                            = ESRCH;
const Errno E_INTR                            = EINTR;
const Errno E_IO                              = EIO;
const Errno E_NXIO                            = ENXIO;
const Errno E_BADF                            = EBADF;
const Errno E_CHILD                           = ECHILD;
const Errno E_ACCES                           = EACCES;
const Errno E_FAULT                           = EFAULT;
const Errno E_EXIST                           = EEXIST;
const Errno E_NODEV                           = ENODEV;
const Errno E_NOTDIR                          = ENOTDIR;
const Errno E_ISDIR                           = EISDIR;
const Errno E_INVAL                           = EINVAL;
const Errno E_NFILE                           = ENFILE;
const Errno E_MFILE                           = EMFILE;
const Errno E_FBIG                            = EFBIG;
const Errno E_NOSPC                           = ENOSPC;
const Errno E_SPIPE                           = ESPIPE;
const Errno E_ROFS                            = EROFS;
const Errno E_PIPE                            = EPIPE;
const Errno E_AGAIN                           = EAGAIN;
const Errno E_WOULDBLOCK                      = EWOULDBLOCK;
const Errno E_INPROGRESS                      = EINPROGRESS;
const Errno E_NOTSOCK                         = ENOTSOCK;
const Errno E_NOTCONN @if(env::LINUX)         = (Errno)107;
const Errno E_NOTCONN @if(env::DARWIN)        = ENOTCONN;
const Errno E_SHUTDOWN @if(env::LINUX)        = (Errno)108;
const Errno E_SHUTDOWN @if(env::DARWIN)       = ESHUTDOWN;
const Errno E_PROTONOSUPPORT @if(env::LINUX)  = (Errno)93;
const Errno E_PROTONOSUPPORT @if(env::DARWIN) = EPROTONOSUPPORT;
const Errno E_OPNOTSUPP                       = EOPNOTSUPP;
const Errno E_AFNOSUPPORT @if(env::LINUX)     = (Errno)97;
const Errno E_AFNOSUPPORT @if(env::DARWIN)    = EAFNOSUPPORT;
const Errno E_ADDRINUSE                       = EADDRINUSE;
const Errno E_ADDRNOTAVAIL                    = EADDRNOTAVAIL;
const Errno E_NETUNREACH                      = ENETUNREACH;
const Errno E_CONNRESET                       = ECONNRESET;
const Errno E_CONNABORTED @if(env::LINUX)     = (Errno)103;
const Errno E_CONNABORTED @if(env::DARWIN)    = (Errno)53;
const Errno E_TIMEDOUT                        = ETIMEDOUT;
const Errno E_CONNREFUSED                     = ECONNREFUSED;
const Errno E_LOOP                            = ELOOP;
const Errno E_NAMETOOLONG                     = ENAMETOOLONG;
const Errno E_NOTEMPTY                        = ENOTEMPTY;
const Errno E_DQUOT                           = EDQUOT;
const Errno E_NOSYS                           = env::LINUX ? (Errno)38 : (Errno)78;
const Errno E_XDEV                            = (Errno)18;
const Errno E_OVERFLOW                        = EOVERFLOW;
