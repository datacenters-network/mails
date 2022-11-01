#!/bin/sh

set -eu

##
# This user script will be executed between configuration and starting daemons
# To enable it you must save it in your config directory as "user-patches.sh"
##
echo ">>>>>>>>>>>>>>>>>>>>>>>Applying patches<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<"

# https://github.com/dovecot/core/blob/941668f5a0ca1733ceceae438092398bc08a7810/doc/example-config/dovecot-ldap.conf.ext#L47

#printf '\ntls_ca_cert_file = %s\ntls_cert_file = %s\ntls_key_file = %s\ntls_require_cert = %s\n' \
#    "${DOVECOT_TLS_CACERT_FILE}" \
#    "${DOVECOT_TLS_CERT_FILE}" \
#    "${DOVECOT_TLS_KEY_FILE}" \
#    "${DOVECOT_TLS_VERIFY_CLIENT}" >> /etc/dovecot/dovecot-ldap.conf.ext

cat >/etc/postfix/sasl/smtpd.conf << EOF
pwcheck_method: saslauthd
saslauthd_path: /var/run/saslauthd/mux
mech_list: PLAIN SRP
EOF

# Delete before set to localhost
sed -i '/^mydomain =/d' /etc/postfix/main.cf
sed -i '/^mydestination =/d' /etc/postfix/main.cf

# Delete this value to default as empty default
sed -i '/^smtpd_sasl_local_domain =/d' /etc/postfix/main.cf

printf '\nmydomain = %s\n' "localhost" >> /etc/postfix/main.cf
printf '\nmydestination = %s\n' "localhost" >> /etc/postfix/main.cf
# For: https://github.com/GermanCoding/Roundcube_TLS_Icon
printf '\nsmtpd_tls_received_header = yes\n' "localhost" >> /etc/postfix/main.cf

sed -i '/^smtp_helo_name =/d' /etc/postfix/main.cf
printf '\nsmtp_helo_name = %s\n' "${OVERRIDE_HOSTNAME}" >> /etc/postfix/main.cf

echo 'Add spam check config'

cat <<EOF > /etc/amavis/conf.d/50-user
use strict;

#
# Place your configuration directives here.  They will override those in
# earlier files.
#
# See /usr/share/doc/amavisd-new/ for documentation and examples of
# the directives you can use in this file
#

@local_domains_acl = ( ["."] );
@local_domains_maps = ( ["."] );

@spam_scanners = ( ['SpamAssassin', 'Amavis::SpamControl::SpamAssassin'] );

# To disable virus or spam checks, uncomment the following:
#
# @bypass_virus_checks_maps = (1);  # controls running of anti-virus code
# @bypass_spam_checks_maps  = (1);  # controls running of anti-spam code
# \$bypass_decode_parts = 1;         # controls running of decoders & dearchivers

\$sa_tag_level_deflt = -9999; # always add spam info headers

\$enable_dkim_verification = 1; # Check DKIM

\$virus_admin = "${VIRUS_ADMIN_EMAIL}";

\$X_HEADER_LINE = "${VIRUS_X_HEADER_LINE}";

#------------ Do not modify anything below this line -------------
1;  # ensure a defined return
EOF

if [ -f /etc/amavis/conf.d/60-dms_default_config ]; then
    echo 'Removed to fix (https://github.com/docker-mailserver/docker-mailserver/issues/2123)'
    rm /etc/amavis/conf.d/60-dms_default_config
fi

echo 'Tweak spamassassin'

# Remove the possible line
sed -i '/^add_header all Report _REPORT_$/d' /etc/spamassassin/local.cf
# Add it back
printf '\nadd_header all Report _REPORT_\n' >> /etc/spamassassin/local.cf

echo 'Lint spamassassin'
spamassassin --lint

echo 'Tweak fail2ban config'

cat <<EOF > /etc/fail2ban/jail.d/user-jail.local
[DEFAULT]

# "bantime" is the number of seconds that a host is banned.
# 86400s = 1 day
bantime  = 86400s

# A host is banned if it has generated "maxretry" during the last "findtime"
# seconds.
#findtime  = 10m

# "maxretry" is the number of failures before a host get banned.
#maxretry = 5

# "ignoreip" can be a list of IP addresses, CIDR masks or DNS hosts. Fail2ban
# will not ban a host which matches an address in this list. Several addresses
# can be defined using space (and/or comma) separator.
ignoreip = ${FAIL2BAN_IGNORE_IPS}

# Default ban action
# iptables-multiport:	block IP only on affected port
# iptables-allports:	block IP on all ports
#banaction = iptables-allports

# Email settings

destemail = ${FAIL2BAN_DST_EMAIL}
sender = ${FAIL2BAN_SENDER_EMAIL}
sendername = ${FAIL2BAN_SENDER_NAME}
mta = sendmail

# to ban & send an e-mail with whois report to the destemail.
#action = %(action_mw)s

# same as action_mw but also send relevant log lines
action = %(action_mwl)s

[recidive]
enabled = true
banaction = %(banaction_allports)s
bantime  = 1w
findtime = 1h

EOF

echo 'Enabling replication'

sed -i '/^iterate_filter =/d' /etc/dovecot/dovecot-ldap.conf.ext
sed -i '/^iterate_attrs =/d' /etc/dovecot/dovecot-ldap.conf.ext

printf '\niterate_filter = (objectClass=PostfixBookMailAccount)\n' >> /etc/dovecot/dovecot-ldap.conf.ext
printf '\niterate_attrs = mail=user\n' >> /etc/dovecot/dovecot-ldap.conf.ext

sed -i 's/^mail_plugins =.*/mail_plugins = \$mail_plugins notify replication/' /etc/dovecot/conf.d/10-mail.conf

cat <<EOF > /etc/dovecot/conf.d/10-replication.conf
service doveadm {
	inet_listener {
		port = 4177
		ssl = yes
	}
}
ssl = required
ssl_verify_client_cert = no
auth_ssl_require_client_cert = no
ssl_cert = <${SSL_CERT_PATH}
ssl_key = <${SSL_KEY_PATH}
ssl_client_ca_file = ${DOVECOT_TLS_CACERT_FILE}
ssl_client_ca_dir = /etc/ssl/certs/
doveadm_port = 4177
doveadm_password = ${DOVECOT_ADM_PASS}
service replicator {
	process_min_avail = 1
	unix_listener replicator-doveadm {
		user = dovecot
        group = dovecot
		mode = 0666
	}
}
service aggregator {
	fifo_listener replication-notify-fifo {
		user = dovecot
        group = dovecot
        mode = 0666
	}
	unix_listener replication-notify {
		user = dovecot
        group = dovecot
        mode = 0666
	}
}
EOF

# Check if configured
if [ -n "${DOVECOT_REPLICA_SERVER}" ]; then
    # Open the config
    sed -i '/^}/d' /etc/dovecot/conf.d/90-plugin.conf
    # Remove a possible old value of mail_replica
    sed -i '/^mail_replica/d' /etc/dovecot/conf.d/90-plugin.conf
    # Insert the config and close it back
    printf '\nmail_replica = tcps:%s\n}\n' "${DOVECOT_REPLICA_SERVER}" >> /etc/dovecot/conf.d/90-plugin.conf
fi

echo ">>>>>>>>>>>>>>>>>>>>>>>Finished applying patches<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<"
