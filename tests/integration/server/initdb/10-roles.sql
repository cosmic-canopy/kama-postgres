-- The roles the integration tests authenticate as — one per method in pg_hba.conf — and their database.
-- The passwords are test constants, repeated in tools/pg.sh's environment file; nothing here is secret.

SET password_encryption = 'scram-sha-256';
CREATE ROLE kp_scram    LOGIN PASSWORD 'kp_scram_pw';
CREATE ROLE kp_password LOGIN PASSWORD 'kp_password_pw';   -- stored as SCRAM; the `password` method
                                                          -- sends cleartext and the server checks it
CREATE ROLE kp_ssl_only LOGIN PASSWORD 'kp_ssl_only_pw';
CREATE ROLE kp_nossl    LOGIN PASSWORD 'kp_nossl_pw';
CREATE ROLE kp_trust    LOGIN;
CREATE ROLE kp_cert     LOGIN;

-- Stored as md5 so the server issues an md5 challenge (deprecated since PostgreSQL 18, still supported).
SET password_encryption = 'md5';
CREATE ROLE kp_md5      LOGIN PASSWORD 'kp_md5_pw';
RESET password_encryption;

CREATE DATABASE kp_test OWNER kp_scram;
