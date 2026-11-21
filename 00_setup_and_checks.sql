-- 00_setup_and_checks.sql
-- One-off server setting needed before 01 (LOAD DATA LOCAL INFILE), plus a quick check after loading.

SET GLOBAL local_infile = 1;

SELECT COUNT(*) FROM airbnb_raw.raw_bookings;