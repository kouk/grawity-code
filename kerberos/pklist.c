/*
 * pklist.c - parseable 'klist'
 *
 * © 2010 Mantas M. <grawity@gmail.com>
 * Released under WTFPL v2 <http://sam.zoy.org/wtfpl/>
 * Portions of code lifted from MIT Kerberos (clients/klist/klist.c)
 */

#define _GNU_SOURCE

#include <stdlib.h>
#include <stdio.h>
#include <unistd.h>
#include <string.h>
#include "krb5.h"

#ifdef KRB5_MIT
#	define HAVE_COLLECTIONS
#	define HAVE_KRB5_CONFIG_PRINCIPALS
#endif

#ifdef KRB5_HEIMDAL
#	ifdef HAVE_COLLECTIONS
#		include <krb5_ccapi.h>
#	endif
#	define krb5_free_default_realm(ctx, realm)	krb5_xfree(realm)
#	define krb5_free_host_realm(ctx, realm)		krb5_xfree(realm)
#	define krb5_free_unparsed_name(ctx, name)	krb5_xfree(name)
#endif

#ifndef HAVE_KRB5_CONFIG_PRINCIPALS
#	define krb5_is_config_principal(ctx, princ)	(0)
/*
krb5_boolean krb5_is_config_principal(krb5_context, krb5_const_principal) {
	return 0;
}
*/
#endif

char *progname = "pklist";
krb5_context ctx;
int show_cfg_tkts = 0;
int show_collection = 0;
int show_ccname_only = 0;
int show_tktdata = 0;
int show_defname_only = 0;
int show_names_only = 0;
int show_realm_only = 0;
int show_header_only = 0;
int quiet_errors = 0;

int do_realm(char*);
int do_ccache(krb5_ccache);
int do_ccache_by_name(char*);
int do_collection();
void show_cred(register krb5_creds*);
char* strflags(register krb5_creds*);
krb5_error_code krb5_cc_get_principal_name(krb5_context, krb5_ccache, char**);
krb5_ccache resolve_ccache(char*);

int main(int argc, char *argv[]) {
	int opt;
	int ret;
	char *ccname = NULL;
	char *hostname = NULL;
	krb5_error_code retval;

	while ((opt = getopt(argc, argv, "Cc:lNPpRr:T")) != -1) {
		switch (opt) {
		case 'C':
			show_cfg_tkts++;
			break;
		case 'c':
			ccname = optarg;
			break;
		case 'l':
			show_collection++;
			quiet_errors = 1;
			break;
		case 'N':
			show_ccname_only = 1;
			break;
		case 'P':
			show_defname_only = 1;
			break;
		case 'p':
			show_names_only = 1;
			break;
		case 'R':
			show_realm_only = 1;
			break;
		case 'r':
			show_realm_only = 1;
			hostname = optarg;
			break;
		case 'T':
			show_tktdata = 1;
			break;
		case '?':
		default:
			fprintf(stderr,
				"Usage: %s [-ClT] [-N|-P|-p|-R|-r hostname] [-c ccname]\n",
				progname);
			fprintf(stderr,
				"\n"
				"\t-C         list configuration tickets\n"
				"\t-CC        - show raw config ticket names\n"
				"\t-c ccname  show contents of given ccache\n"
				"\t-l         list known ccaches\n"
				"\t-ll        - also show contents\n"
				"\t-N         only show ccache name\n"
				"\t-P         show default client principal\n"
				"\t-p         only show principal names\n"
				"\t-R         show default realm\n"
				"\t-r host    show realm for given FQDN\n"
				"\t-T         show ticket data\n");
			exit(2);
		}
	}

	retval = krb5_init_context(&ctx);
	if (retval) {
		com_err(progname, retval, "while initializing krb5");
		exit(1);
	}

	if (show_collection)
		ret = do_collection();
	else if (show_realm_only)
		ret = do_realm(hostname);
	else
		ret = do_ccache_by_name(ccname);

	krb5_free_context(ctx);

	return ret;
}

/*
 * Find the realm for given hostname
 */
int do_realm(char *hostname) {
	krb5_error_code	retval;
	char		**realm;

	if (hostname) {
		retval = krb5_get_host_realm(ctx, hostname, &realm);
		if (retval) {
			com_err(progname, retval, "while obtaining realm for %s", hostname);
			exit(1);
		}
		printf("%s\n", *realm);
		krb5_free_host_realm(ctx, realm);
	} else {
		realm = malloc(sizeof(realm));
		retval = krb5_get_default_realm(ctx, realm);
		if (retval) {
			com_err(progname, retval, "while obtaining default realm");
			exit(1);
		}
		printf("%s\n", *realm);
		krb5_free_default_realm(ctx, *realm);
		free(realm);
	}
	return 0;
}

/*
 * Output the ccache contents
 */
int do_ccache(krb5_ccache cache) {
	char		*ccname = NULL;
	krb5_creds	creds;
	krb5_cc_cursor	cursor;
	krb5_principal	princ = NULL;
	char		*princname = NULL;
	krb5_flags	flags = 0;
	krb5_error_code	retval;
	int		status = 1;

	asprintf(&ccname, "%s:%s",
		krb5_cc_get_type(ctx, cache),
		krb5_cc_get_name(ctx, cache));
	if (!ccname)
		goto cleanup;

	if (show_ccname_only && !show_collection) {
		// With just -N, always show the name...
		printf("%s\n", ccname);
		status = 0;
		goto cleanup;
	}

	retval = krb5_cc_set_flags(ctx, cache, flags);
	if (retval) {
		if (quiet_errors)
			;
		else if (retval == KRB5_FCC_NOFILE)
			com_err(progname, retval, "(ticket cache %s)", ccname);
		else
			com_err(progname, retval, "while setting cache flags (ticket cache %s)", ccname);
		goto cleanup;
	}

	retval = krb5_cc_get_principal(ctx, cache, &princ);
	if (retval) {
		if (quiet_errors)
			;
		else if (retval == KRB5_FCC_NOFILE)
			com_err(progname, retval, "(ticket cache %s)", ccname);
		else
			com_err(progname, retval, "while obtaining default principal (ticket cache %s)", ccname);
		goto cleanup;
	}

	retval = krb5_unparse_name(ctx, princ, &princname);
	if (retval)
		goto cleanup;

	if (show_ccname_only && show_collection) {
		// ...with -l -N, only show names pointing to valid ccaches.
		printf("%s\n", ccname);
		status = 0;
		goto cleanup;
	}

	if (show_defname_only) {
		printf("%s\n", princname);
		status = 0;
		goto cleanup;
	}

	if (!show_names_only) {
		if (show_collection == 1) {
			// only show the header
			printf("cache\t%s\t%s\n", ccname, princname);
			status = 0;
			goto cleanup;
		} else {
			// TODO: should the format be merged into the one above?
			// separate cache/principal kept for now, for compat reasons
			printf("cache\t%s\n", ccname);
			printf("principal\t%s\n", princname);
		}
		printf("CREDENTIALS\tclient_name\tserver_name\tstart_time\texpiry_time\trenew_time\tflags\tticket_data\n");
	}

	retval = krb5_cc_start_seq_get(ctx, cache, &cursor);
	if (retval) {
		com_err(progname, retval, "while starting to retrieve tickets");
		goto cleanup;
	}

	for (;;) {
		retval = krb5_cc_next_cred(ctx, cache, &cursor, &creds);
		if (retval)
			break;
		show_cred(&creds);
		krb5_free_cred_contents(ctx, &creds);
	}

	if (retval == KRB5_CC_END) {
		krb5_cc_end_seq_get(ctx, cache, &cursor);
		status = 0;
	} else {
		com_err(progname, retval, "while retrieving a ticket");
	}

cleanup:
	if (princ)
		krb5_free_principal(ctx, princ);
	if (princname)
		krb5_free_unparsed_name(ctx, princname);
	if (ccname)
		free(ccname);
	return status;
}

/*
 * Resolve a ccname to krb5_ccache
 */
krb5_ccache resolve_ccache(char *name) {
	krb5_ccache		cache = NULL;
	krb5_error_code		retval;

	if (name == NULL) {
		retval = krb5_cc_default(ctx, &cache);
		if (retval)
			com_err(progname, retval, "while getting default ccache");
	} else {
		retval = krb5_cc_resolve(ctx, name, &cache);
		if (retval)
			com_err(progname, retval, "while resolving ccache %s", name);
	}
	return cache;
}

/*
 * resolve a ccache and output its contents
 */
int do_ccache_by_name(char *name) {
	krb5_ccache		cache;
	int			status = 1;

	cache = resolve_ccache(name);
	if (cache) {
		status = do_ccache(cache);
		krb5_cc_close(ctx, cache);
	}
	return status;
}

/*
 * Display all ccaches in a collection, in short form.
 */
int do_collection() {
#ifdef HAVE_COLLECTIONS
	krb5_error_code		retval;
	krb5_cccol_cursor	cursor;
	krb5_ccache		cache;
#endif

	if (!show_ccname_only && !show_names_only && !show_defname_only) {
		printf("default\t%s\n",
			krb5_cc_default_name(ctx));
		printf("COLLECTION\tccname\tprincipal\n");
	}

#ifdef HAVE_COLLECTIONS
	if ((retval = krb5_cccol_cursor_new(ctx, &cursor))) {
		com_err(progname, retval, "while listing ccache collection");
		exit(1);
	}
	while (!(retval = krb5_cccol_cursor_next(ctx, cursor, &cache))) {
		if (cache == NULL)
			break;
		do_ccache(cache);
		krb5_cc_close(ctx, cache);
	}
	krb5_cccol_cursor_free(ctx, &cursor);
	return 0;
#else
	return do_ccache_by_name(NULL);
#endif
}

void print_data(krb5_data *ticket) {
	unsigned int i;
	for (i = 0; i < ticket->length; i++) {
		if (0x20 < ticket->data[i]
			&& ticket->data[i] < 0x7f)
			putchar(ticket->data[i]);
		else
			printf("\\%03o", (unsigned char) ticket->data[i]);
	}
}

/*
 * output a single credential (ticket)
 */
void show_cred(register krb5_creds *cred) {
	krb5_error_code	retval;
	char		*clientname;
	char		*servername;
	char		*flags;
	int		is_config;
	int		i;

	is_config = krb5_is_config_principal(ctx, cred->server);
	if (is_config && !show_cfg_tkts)
		return;

	retval = krb5_unparse_name(ctx, cred->client, &clientname);
	if (retval) {
		com_err(progname, retval, "while unparsing client name");
		goto cleanup;
	}

	retval = krb5_unparse_name(ctx, cred->server, &servername);
	if (retval) {
		com_err(progname, retval, "while unparsing server name");
		goto cleanup;
	}

	if (show_names_only) {
		printf("%s\n", servername);
		goto cleanup;
	}

	if (!cred->times.starttime)
		cred->times.starttime = cred->times.authtime;
	
	if (is_config && show_cfg_tkts == 1) {
		// "config" <arg>+ <value>
		printf("config");
		printf("\t%d", cred->server->length-1);
		for (i = 1; i < cred->server->length; i++)
			printf("\t%s", cred->server->data[i].data);
		printf("\t");
		print_data(&cred->ticket);
		printf("\n");
	} else {
		// "ticket" <server> <client> <start> <renew> <flags> [data]
		printf(is_config ? "cfgticket" : "ticket");
		printf("\t%s", clientname);
		printf("\t%s", servername);
		printf("\t%ld", (unsigned long) cred->times.starttime);
		printf("\t%ld", (unsigned long) cred->times.endtime);
		printf("\t%ld", (unsigned long) cred->times.renew_till);

		flags = strflags(cred);
		if (flags && *flags)
			printf("\t%s", flags);
		else if (flags)
			printf("\t-");
		else
			printf("\t?");

		if (is_config || show_tktdata) {
			printf("\t");
			print_data(&cred->ticket);
		} else
			printf("\t-");

		printf("\n");
	}

cleanup:
	if (clientname)
		krb5_free_unparsed_name(ctx, clientname);
	if (servername)
		krb5_free_unparsed_name(ctx, servername);
}

/*
 * return Kerberos credential flags in ASCII
 *
 * TODO: can MIT and Heimdal use the same code?
 */
char * strflags(register krb5_creds *cred) {
	static char buf[16];
	int i = 0;

#ifdef KRB5_HEIMDAL
	struct TicketFlags flags = cred->flags.b;

	if (flags.forwardable)			buf[i++] = 'F';
	if (flags.forwarded)			buf[i++] = 'f';
	if (flags.proxiable)			buf[i++] = 'P';
	if (flags.proxy)			buf[i++] = 'p';
	if (flags.may_postdate)			buf[i++] = 'D';
	if (flags.postdated)			buf[i++] = 'd';
	if (flags.invalid)			buf[i++] = 'i';
	if (flags.renewable)			buf[i++] = 'R';
	if (flags.initial)			buf[i++] = 'I';
	if (flags.hw_authent)			buf[i++] = 'H';
	if (flags.pre_authent)			buf[i++] = 'A';
	if (flags.transited_policy_checked)	buf[i++] = 'T';
	if (flags.ok_as_delegate)		buf[i++] = 'O';
	if (flags.anonymous)			buf[i++] = 'a';
#else
	krb5_flags flags = cred->ticket_flags;

	if (flags & TKT_FLG_FORWARDABLE)		buf[i++] = 'F';
	if (flags & TKT_FLG_FORWARDED)			buf[i++] = 'f';
	if (flags & TKT_FLG_PROXIABLE)			buf[i++] = 'P';
	if (flags & TKT_FLG_PROXY)			buf[i++] = 'p';
	if (flags & TKT_FLG_MAY_POSTDATE)		buf[i++] = 'D';
	if (flags & TKT_FLG_POSTDATED)			buf[i++] = 'd';
	if (flags & TKT_FLG_INVALID)			buf[i++] = 'i';
	if (flags & TKT_FLG_RENEWABLE)			buf[i++] = 'R';
	if (flags & TKT_FLG_INITIAL)			buf[i++] = 'I';
	if (flags & TKT_FLG_HW_AUTH)			buf[i++] = 'H';
	if (flags & TKT_FLG_PRE_AUTH)			buf[i++] = 'A';
	if (flags & TKT_FLG_TRANSIT_POLICY_CHECKED)	buf[i++] = 'T';
	if (flags & TKT_FLG_OK_AS_DELEGATE)		buf[i++] = 'O';
	if (flags & TKT_FLG_ANONYMOUS)			buf[i++] = 'a';
#endif

	buf[i] = '\0';	
	return buf;
}
