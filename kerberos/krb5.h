#if 0
#if defined(__SVR4) && defined(__sun)
#  define HAVE_SOLARIS
#endif
#endif

#if defined(HAVE_LINUX)
#	include <krb5/krb5.h>
#elif defined(HAVE_CYGWIN)
#	include <krb5.h>
#elif defined(HAVE_FREEBSD)
#	include <krb5.h>
#	include <com_err.h>
#elif defined(HAVE_NETBSD)
#	include <krb5/krb5.h>
#	include <krb5/com_err.h>
#elif defined(HAVE_SOLARIS)
#	include <kerberosv5/krb5.h>
#	include <kerberosv5/com_err.h>
#else
#	include <krb5.h>
#endif

#ifdef KRB5_KRB5_H_INCLUDED
#	define KRB5_MIT
#elif defined(__KRB5_H__)
#	define KRB5_HEIMDAL
#endif
