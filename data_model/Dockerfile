FROM postgres
COPY cc_schema.sql /tmp
COPY example-bank.pem /tmp
CMD PGPASSWORD=$DB_PASSWORD /usr/bin/psql --host=$DB_SERVERNAME --port=$DB_PORTNUMBER --username=$DB_USER \
--set=sslmode=verify-full --set=sslrootcert=/tmp/example-bank.pem --file=/tmp/cc_schema.sql