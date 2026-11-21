-- =====================================================================
-- 03_cleaning_pipeline.sql  -  airbnb_raw  ->  airbnb_clean   (MySQL 8.0)
-- =====================================================================
-- Per table: raw_<t> -> archive_<t> (exact dups, old versions) -> stg_<t> (parsed)
-- -> manual_issues (one row per problem) -> manual_<t> (rows for review) -> airbnb_clean.
-- Rerunnable. archive/stg/clean are rebuilt each run, manual_<t> edits are kept.
-- Run after 01 and 02. Tested on MySQL 8.0.46, won't run on MariaDB.


USE airbnb_raw;

SET SQL_SAFE_UPDATES = 0;                     -- Workbench blocks UPDATE/DELETE without a key otherwise
SET SESSION group_concat_max_len = 1000000;   -- GROUP_CONCAT is cut at 1024 characters by default
SET lc_time_names = 'en_US';                  -- so STR_TO_DATE understands 'Mar' and 'March'

-- Fixed "today" for this extract, so date rules give the same result whenever it runs.
SET @snapshot_date = DATE('2026-11-19');
-- Nightly price above this = typo (usually 100x).
SET @max_nightly_price = 2000;


-- #####################################################################
-- PART 1. Helper functions
-- Small parsers: messy text in, typed value out, NULL when it's not certain.
-- Every routine has its own DELIMITER $$ ... DELIMITER ; so parts of the file can be run in Workbench.
-- #####################################################################

-- Trim, collapse spaces, null tokens ('N/A', 'null', '-') -> NULL. Case-insensitive via the _ci collation.
DELIMITER $$
DROP FUNCTION IF EXISTS fn_clean_text $$
CREATE FUNCTION fn_clean_text(s TEXT) RETURNS TEXT
DETERMINISTIC NO SQL
BEGIN
  DECLARE t TEXT;
  IF s IS NULL THEN RETURN NULL; END IF;
  SET t = TRIM(REGEXP_REPLACE(s, '[ \t]+', ' '));
  IF t IN ('', 'null', 'n/a', 'none', '-', 'nan') THEN RETURN NULL; END IF;
  RETURN t;
END $$
DELIMITER ;

-- 'JOHN', 'john' -> 'John'. 'van den berg' -> 'van den Berg'. Mixed case like
-- 'McDonald' is left as typed.
-- p_mode 'person' keeps particles lower case; 'place' capitalises the first word ('De Pijp').
DELIMITER $$
DROP FUNCTION IF EXISTS fn_title_case $$
CREATE FUNCTION fn_title_case(s VARCHAR(255), p_mode VARCHAR(6)) RETURNS VARCHAR(255)
DETERMINISTIC NO SQL
BEGIN
  DECLARE i INT DEFAULT 1;
  DECLARE c VARCHAR(1);
  DECLARE prev VARCHAR(1) DEFAULT ' ';
  DECLARE r VARCHAR(300) DEFAULT '';
  IF s IS NULL THEN RETURN NULL; END IF;
  IF CAST(s AS BINARY) <> CAST(UPPER(s) AS BINARY) AND CAST(s AS BINARY) <> CAST(LOWER(s) AS BINARY) THEN
    RETURN s;
  END IF;
  SET s = LOWER(s);
  WHILE i <= CHAR_LENGTH(s) DO
    SET c = SUBSTRING(s, i, 1);
    SET r = CONCAT(r, IF(prev IN (' ', '-', ''''), UPPER(c), c));
    SET prev = c;
    SET i = i + 1;
  END WHILE;
  SET r = CONCAT(' ', r, ' ');
  SET r = REPLACE(r, ' De ', ' de ');   SET r = REPLACE(r, ' Van ', ' van ');
  SET r = REPLACE(r, ' Den ', ' den '); SET r = REPLACE(r, ' Der ', ' der ');
  SET r = REPLACE(r, ' And ', ' and '); SET r = REPLACE(r, ' En ', ' en ');
  SET r = REPLACE(r, '-Des-', '-des-');
  SET r = TRIM(r);
  IF p_mode = 'place' THEN SET r = CONCAT(UPPER(LEFT(r, 1)), SUBSTRING(r, 2)); END IF;
  RETURN r;
END $$
DELIMITER ;

-- Free text (titles, comments): ALL CAPS or all lower case -> sentence case
-- ('GREAT STAY. LOVED IT' -> 'Great stay. Loved it').
DELIMITER $$
DROP FUNCTION IF EXISTS fn_sentence_case $$
CREATE FUNCTION fn_sentence_case(s TEXT) RETURNS TEXT
DETERMINISTIC NO SQL
BEGIN
  DECLARE i INT DEFAULT 1;
  DECLARE c VARCHAR(1);
  DECLARE cap_next BOOLEAN DEFAULT TRUE;
  DECLARE r TEXT DEFAULT '';
  IF s IS NULL THEN RETURN NULL; END IF;
  IF CAST(s AS BINARY) <> CAST(UPPER(s) AS BINARY) AND CAST(s AS BINARY) <> CAST(LOWER(s) AS BINARY) THEN
    RETURN s;
  END IF;
  SET s = LOWER(s);
  WHILE i <= CHAR_LENGTH(s) DO
    SET c = SUBSTRING(s, i, 1);
    IF cap_next AND CAST(UPPER(c) AS BINARY) <> CAST(c AS BINARY) THEN
      SET r = CONCAT(r, UPPER(c));
      SET cap_next = FALSE;
    ELSE
      SET r = CONCAT(r, c);
      IF c IN ('.', '!', '?', CHAR(10)) THEN SET cap_next = TRUE;
      ELSEIF c NOT IN (' ', '"') THEN SET cap_next = FALSE; END IF;
    END IF;
    SET i = i + 1;
  END WHILE;
  RETURN r;
END $$
DELIMITER ;

-- Free text repair: HTML tags and entities, mojibake ('cafÃ©' -> 'café'), spacing, casing.
DELIMITER $$
DROP FUNCTION IF EXISTS fn_fix_text $$
CREATE FUNCTION fn_fix_text(s TEXT) RETURNS TEXT
DETERMINISTIC NO SQL
BEGIN
  DECLARE t TEXT;
  IF s IS NULL THEN RETURN NULL; END IF;
  -- REPLACE() is case-sensitive, which is fine here
  SET t = REPLACE(REPLACE(REPLACE(s, '<br>', CHAR(10)), '<br/>', CHAR(10)), '<br />', CHAR(10));
  SET t = REGEXP_REPLACE(t, '<[^>]+>', '');                       -- any other tag: <p>, </p>, <b>...
  SET t = REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(t,
            '&amp;', '&'), '&lt;', '<'), '&gt;', '>'), '&quot;', '"'), '&#39;', ''''), '&nbsp;', ' ');
  -- UTF-8 text that was decoded as Latin-1 at some point (mojibake)
  SET t = REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(t,
            'Ã©', 'é'), 'Ã¨', 'è'), 'Ã§', 'ç'), 'Ã¶', 'ö'), 'Ã¼', 'ü'), 'Ã±', 'ñ');
  RETURN fn_sentence_case(fn_clean_text(t));
END $$
DELIMITER ;

-- Handles every date/datetime format in the raw files.
-- p_mode = 'strict' : ambiguous slash date like 03/04/2024 -> NULL
-- p_mode = 'dmy'    : ambiguous slash dates read as DD/MM   (only for suggestions)
-- p_mode = 'mdy'    : ambiguous slash dates read as MM/DD
DELIMITER $$
DROP FUNCTION IF EXISTS fn_parse_datetime $$
CREATE FUNCTION fn_parse_datetime(s VARCHAR(255), p_mode VARCHAR(6)) RETURNS DATETIME
DETERMINISTIC NO SQL
BEGIN
  DECLARE t VARCHAR(255);
  DECLARE a INT; DECLARE b INT; DECLARE dd INT; DECLARE mm INT;
  DECLARE y VARCHAR(4);
  DECLARE tm VARCHAR(10) DEFAULT '00:00:00';
  -- Invalid dates (e.g. 31/02/2024) -> NULL instead of an error.
  DECLARE EXIT HANDLER FOR SQLEXCEPTION, SQLWARNING RETURN NULL;

  SET t = fn_clean_text(s);
  IF t IS NULL THEN RETURN NULL; END IF;

  -- digits only
  IF REGEXP_LIKE(t, '^[0-9]{5}$') THEN                                  -- Excel serial day number, 45366
    RETURN DATE_ADD('1899-12-30', INTERVAL t DAY);
  ELSEIF REGEXP_LIKE(t, '^[0-9]{8}$') THEN                              -- 20240315
    RETURN STR_TO_DATE(t, '%Y%m%d');
  ELSEIF REGEXP_LIKE(t, '^[0-9]{9,10}$') THEN                           -- unix epoch seconds (UTC)
    RETURN DATE_ADD('1970-01-01 00:00:00', INTERVAL t SECOND);
  END IF;

  -- ISO, optionally with a time, a 'T' and a 'Z':  2024-03-15 / 2024-03-15 10:00:00 / 2024-03-15T10:00:00Z
  IF REGEXP_LIKE(t, '^[0-9]{4}-[0-9]{2}-[0-9]{2}([ T][0-9]{2}:[0-9]{2}(:[0-9]{2})?Z?)?$') THEN
    RETURN CAST(REPLACE(REPLACE(t, 'T', ' '), 'Z', '') AS DATETIME);
  END IF;
  IF REGEXP_LIKE(t, '^[0-9]{4}/[0-9]{2}/[0-9]{2}$') THEN RETURN STR_TO_DATE(t, '%Y/%m/%d'); END IF;          -- 2024/03/15
  IF REGEXP_LIKE(t, '^[0-9]{2}[.][0-9]{2}[.][0-9]{4}$') THEN RETURN STR_TO_DATE(t, '%d.%m.%Y'); END IF;      -- 15.03.2024
  IF REGEXP_LIKE(t, '^[0-9]{1,2}-[a-z]{3}-[0-9]{4}$') THEN RETURN STR_TO_DATE(t, '%d-%b-%Y'); END IF;        -- 15-Mar-2024
  IF REGEXP_LIKE(t, '^[0-9]{1,2}-[a-z]{3}-[0-9]{4} [0-9]{1,2}:[0-9]{2} [ap]m$') THEN                         -- 15-Mar-2024 10:00 AM
    RETURN STR_TO_DATE(t, '%d-%b-%Y %h:%i %p');
  END IF;
  IF REGEXP_LIKE(t, '^[a-z]+ [0-9]{1,2}, [0-9]{4}$') THEN RETURN STR_TO_DATE(t, '%M %d, %Y'); END IF;        -- March 15, 2024

  -- Slash dates: 25/12/2024 is clearly DD/MM, 12/25/2024 is clearly MM/DD, 03/04/2024 is ambiguous.
  IF REGEXP_LIKE(t, '^[0-9]{1,2}/[0-9]{1,2}/[0-9]{4}( [0-9]{1,2}:[0-9]{2}(:[0-9]{2})?)?$') THEN
    SET a = SUBSTRING_INDEX(t, '/', 1);
    SET b = SUBSTRING_INDEX(SUBSTRING_INDEX(t, '/', 2), '/', -1);
    SET y = LEFT(SUBSTRING_INDEX(t, '/', -1), 4);
    IF LOCATE(' ', t) > 0 THEN SET tm = SUBSTRING_INDEX(t, ' ', -1); END IF;
    IF a > 12 THEN SET dd = a; SET mm = b;
    ELSEIF b > 12 THEN SET mm = a; SET dd = b;
    ELSEIF a = b THEN SET dd = a; SET mm = b;
    ELSEIF p_mode = 'dmy' THEN SET dd = a; SET mm = b;
    ELSEIF p_mode = 'mdy' THEN SET mm = a; SET dd = b;
    ELSE RETURN NULL;                                                   -- ambiguous, left for manual review
    END IF;
    RETURN CAST(CONCAT(y, '-', mm, '-', dd, ' ', tm) AS DATETIME);
  END IF;

  RETURN NULL;                                                          -- unknown format
END $$
DELIMITER ;

-- Money: '£120.00', 'EUR 99.50', '99.50 EUR', '120,50', '1,234.50', '1.234,50', '(55.00)', ' 120 '.
-- NULL for '$' amounts (conflicts with GBP/EUR) and for '1.234' (thousands or decimal?).
DELIMITER $$
DROP FUNCTION IF EXISTS fn_parse_money $$
CREATE FUNCTION fn_parse_money(s VARCHAR(255)) RETURNS DECIMAL(14,2)
DETERMINISTIC NO SQL
BEGIN
  DECLARE t VARCHAR(255);
  DECLARE neg BOOLEAN DEFAULT FALSE;
  DECLARE EXIT HANDLER FOR SQLEXCEPTION, SQLWARNING RETURN NULL;
  SET t = fn_clean_text(s);
  IF t IS NULL OR LOCATE('$', t) > 0 THEN RETURN NULL; END IF;
  IF t LIKE '(%)' THEN                                                   -- accounting style negative
    SET neg = TRUE;
    SET t = SUBSTRING(t, 2, CHAR_LENGTH(t) - 2);
  END IF;
  SET t = REGEXP_REPLACE(t, '(GBP|EUR|£|€|\\s)', '');                   -- currency symbols, codes, spaces
  IF t LIKE '-%' THEN SET neg = NOT neg; SET t = SUBSTRING(t, 2); END IF;
  SET t = CASE
    WHEN REGEXP_LIKE(t, '^[0-9]+([.][0-9]{1,2})?$')             THEN t                                 -- 120 / 120.5 / 120.50
    WHEN REGEXP_LIKE(t, '^[0-9]{1,3}[.][0-9]{2}0$')            THEN LEFT(t, CHAR_LENGTH(t) - 1)       -- 120.500 (extra zero)
    WHEN REGEXP_LIKE(t, '^[0-9]+,[0-9]{1,2}$')                 THEN REPLACE(t, ',', '.')              -- 120,50
    WHEN REGEXP_LIKE(t, '^[0-9]{1,3}(,[0-9]{3})+([.][0-9]{1,2})?$') THEN REPLACE(t, ',', '')          -- 1,234.50
    WHEN REGEXP_LIKE(t, '^[0-9]{1,3}([.][0-9]{3})+,[0-9]{1,2}$')    THEN REPLACE(REPLACE(t, '.', ''), ',', '.')  -- 1.234,50
    ELSE NULL END;
  IF t IS NULL THEN RETURN NULL; END IF;
  RETURN IF(neg, -1, 1) * CAST(t AS DECIMAL(14,2));
END $$
DELIMITER ;

-- Reason a money value didn't parse, used as the issue code on manual rows.
DELIMITER $$
DROP FUNCTION IF EXISTS fn_money_problem $$
CREATE FUNCTION fn_money_problem(s VARCHAR(255)) RETURNS VARCHAR(40)
DETERMINISTIC NO SQL
BEGIN
  DECLARE t VARCHAR(255);
  SET t = fn_clean_text(s);
  IF t IS NULL OR fn_parse_money(t) IS NOT NULL THEN RETURN NULL; END IF;
  IF LOCATE('$', t) > 0 THEN RETURN 'dollar_sign_vs_currency'; END IF;
  IF REGEXP_LIKE(REGEXP_REPLACE(t, '(GBP|EUR|£|€|\\s|[()-])', ''), '^[0-9]{1,3}([.][0-9]{3})+$') THEN
    RETURN 'ambiguous_thousands_or_decimal';
  END IF;
  RETURN 'unparseable_money';
END $$
DELIMITER ;

-- First number in a text: '2 bedrooms' -> 2, '1.5 baths' -> 1.5, '4/5' -> 4, 'five' -> 5, 'Half-bath' -> 0.5.
DELIMITER $$
DROP FUNCTION IF EXISTS fn_parse_number $$
CREATE FUNCTION fn_parse_number(s VARCHAR(255)) RETURNS DECIMAL(14,6)
DETERMINISTIC NO SQL
BEGIN
  DECLARE t VARCHAR(255);
  DECLARE EXIT HANDLER FOR SQLEXCEPTION, SQLWARNING RETURN NULL;
  SET t = LOWER(fn_clean_text(s));
  IF t IS NULL THEN RETURN NULL; END IF;
  IF t LIKE 'half%' THEN RETURN 0.5; END IF;
  SET t = CASE t WHEN 'one' THEN '1' WHEN 'two' THEN '2' WHEN 'three' THEN '3' WHEN 'four' THEN '4'
                 WHEN 'five' THEN '5' ELSE t END;
  -- Goes through a variable on purpose: CAST(REGEXP_SUBSTR(...) AS DECIMAL) directly
  -- drops the decimals in MySQL 8.0 (52.3676 -> 52).
  SET t = REGEXP_SUBSTR(t, '-?[0-9]+([.][0-9]+)?');
  RETURN CAST(t AS DECIMAL(14,6));
END $$
DELIMITER ;

-- Response rate in percent: '97%', '97 %', '97' and '0.97' all become 97.
DELIMITER $$
DROP FUNCTION IF EXISTS fn_parse_percent $$
CREATE FUNCTION fn_parse_percent(s VARCHAR(255)) RETURNS INT
DETERMINISTIC NO SQL
BEGIN
  DECLARE t VARCHAR(255);
  DECLARE n DECIMAL(14,6);
  SET t = fn_clean_text(s);
  SET n = fn_parse_number(t);
  IF n IS NULL THEN RETURN NULL; END IF;
  IF LOCATE('%', t) = 0 AND LOCATE('.', t) > 0 AND n <= 1 THEN SET n = n * 100; END IF;
  RETURN ROUND(n);
END $$
DELIMITER ;

-- 't', 'TRUE', 'yes', 'Y', '1' -> 1 ;  'f', 'False', 'no', 'N', '0' -> 0 ; anything else -> NULL
DELIMITER $$
DROP FUNCTION IF EXISTS fn_parse_bool $$
CREATE FUNCTION fn_parse_bool(s VARCHAR(255)) RETURNS TINYINT
DETERMINISTIC NO SQL
BEGIN
  DECLARE t VARCHAR(255);
  SET t = LOWER(fn_clean_text(s));
  IF t IN ('t', 'true', 'yes', 'y', '1') THEN RETURN 1; END IF;
  IF t IN ('f', 'false', 'no', 'n', '0') THEN RETURN 0; END IF;
  RETURN NULL;
END $$
DELIMITER ;

-- IDs: ' 123', '000123', '123.0' -> 123. Anything that isn't a whole number -> NULL.
DELIMITER $$
DROP FUNCTION IF EXISTS fn_parse_id $$
CREATE FUNCTION fn_parse_id(s VARCHAR(255)) RETURNS INT UNSIGNED
DETERMINISTIC NO SQL
BEGIN
  DECLARE t VARCHAR(255);
  SET t = TRIM(s);
  IF t IS NULL OR NOT REGEXP_LIKE(t, '^[0-9]{1,9}([.]0+)?$') THEN RETURN NULL; END IF;
  RETURN CAST(SUBSTRING_INDEX(t, '.', 1) AS UNSIGNED);
END $$
DELIMITER ;

-- Phone -> E.164 (+447700900123). National numbers ('07700 900123', '(770) 090-0123')
-- use the calling code passed in.
DELIMITER $$
DROP FUNCTION IF EXISTS fn_phone_e164 $$
CREATE FUNCTION fn_phone_e164(s VARCHAR(255), p_calling_code VARCHAR(4)) RETURNS VARCHAR(40)
DETERMINISTIC NO SQL
BEGIN
  DECLARE t VARCHAR(255);
  SET t = fn_clean_text(s);
  IF t IS NULL THEN RETURN NULL; END IF;
  SET t = REGEXP_REPLACE(t, '^tel:', '');
  SET t = REGEXP_REPLACE(t, '[ ().-]', '');                         -- separators
  IF t LIKE '+%' THEN RETURN t; END IF;                              -- already international
  IF t LIKE '00%' THEN RETURN CONCAT('+', SUBSTRING(t, 3)); END IF;  -- 0044... -> +44...
  IF t LIKE '0%' THEN RETURN CONCAT('+', p_calling_code, SUBSTRING(t, 2)); END IF;  -- trunk 0
  RETURN CONCAT('+', p_calling_code, t);                             -- national without the 0
END $$
DELIMITER ;

DELIMITER $$
DROP FUNCTION IF EXISTS fn_is_valid_email $$
CREATE FUNCTION fn_is_valid_email(e VARCHAR(255)) RETURNS BOOLEAN
DETERMINISTIC NO SQL
RETURN REGEXP_LIKE(e, '^[a-z0-9._%+-]+@[a-z0-9-]+([.][a-z0-9-]+)*[.][a-z]{2,}$') $$
DELIMITER ;

-- Category lookup in map_values (PART 2). Unknown values -> NULL.
DELIMITER $$
DROP FUNCTION IF EXISTS fn_map $$
CREATE FUNCTION fn_map(p_domain VARCHAR(30), s VARCHAR(255)) RETURNS VARCHAR(60)
DETERMINISTIC READS SQL DATA
BEGIN
  DECLARE v VARCHAR(60) DEFAULT NULL;
  SELECT canonical INTO v FROM map_values
  WHERE domain = p_domain AND raw_value = LOWER(fn_clean_text(s))
  LIMIT 1;
  RETURN v;
END $$
DELIMITER ;


-- #####################################################################
-- PART 1b. Helper procedures for the steps shared by every table.
-- Dynamic SQL (CONCAT + PREPARE/EXECUTE) since the table name is a parameter.
-- Table-specific business rules are all in PART 3.
-- #####################################################################

-- Runs the SQL string in @sql.
DELIMITER $$
DROP PROCEDURE IF EXISTS sp_exec $$
CREATE PROCEDURE sp_exec()
BEGIN
  PREPARE st FROM @sql;
  EXECUTE st;
  DEALLOCATE PREPARE st;
END $$
DELIMITER ;

-- Creates archive_<t> and manual_<t> if missing (manual edits survive reruns)
-- and the view src_<t> = rows to process this run:
--   raw rows not archived and not already handled in manual_<t>
--   + rows marked fixed/approved in manual_<t> (with the edited values)
DELIMITER $$
DROP PROCEDURE IF EXISTS sp_setup_table $$
CREATE PROCEDURE sp_setup_table(IN p_table VARCHAR(64))
BEGIN
  DECLARE v_cols TEXT;
  SELECT GROUP_CONCAT(CONCAT('`', column_name, '`') ORDER BY ordinal_position) INTO v_cols
  FROM information_schema.columns
  WHERE table_schema = DATABASE() AND table_name = CONCAT('raw_', p_table)
    AND column_name NOT IN ('raw_row_id', 'source_file', 'loaded_at');

  SET @sql = CONCAT('CREATE TABLE IF NOT EXISTS archive_', p_table, ' (',
    ' raw_row_id BIGINT UNSIGNED NOT NULL PRIMARY KEY,',
    ' archive_reason VARCHAR(40) NOT NULL DEFAULT '''',',
    ' kept_raw_row_id BIGINT UNSIGNED NULL COMMENT ''the raw row that was kept instead'',',
    ' archived_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP',
    ') SELECT raw_row_id, ', v_cols, ' FROM raw_', p_table, ' WHERE 1 = 0');
  CALL sp_exec();

  SET @sql = CONCAT('CREATE TABLE IF NOT EXISTS manual_', p_table, ' (',
    ' raw_row_id BIGINT UNSIGNED NOT NULL PRIMARY KEY,',
    ' review_status ENUM(''open'',''fixed'',''approved'',''rejected'',''merged'') NOT NULL DEFAULT ''open'',',
    ' issue_summary TEXT NULL,',
    ' suggested_fix TEXT NULL,',
    ' in_clean TINYINT NOT NULL DEFAULT 0 COMMENT ''1 = loaded to clean (with NULLs), 0 = held back'',',
    ' needs_action TINYINT NOT NULL DEFAULT 1 COMMENT ''0 = only waiting for a parent row'',',
    ' merge_into_id INT UNSIGNED NULL,',
    ' reviewer_note VARCHAR(500) NULL,',
    ' first_flagged_at DATETIME NULL,',
    ' last_checked_at DATETIME NULL,',
    ' KEY ix_status (review_status)',
    ') SELECT raw_row_id, ', v_cols, ' FROM raw_', p_table, ' WHERE 1 = 0');
  CALL sp_exec();

  SET @sql = CONCAT('CREATE OR REPLACE VIEW src_', p_table, ' AS ',
    'SELECT r.raw_row_id, ', v_cols, ' FROM raw_', p_table, ' r ',
    'WHERE NOT EXISTS (SELECT 1 FROM archive_', p_table, ' a WHERE a.raw_row_id = r.raw_row_id) ',
    '  AND NOT EXISTS (SELECT 1 FROM manual_', p_table, ' m WHERE m.raw_row_id = r.raw_row_id AND m.review_status <> ''open'') ',
    'UNION ALL ',
    'SELECT m.raw_row_id, ', v_cols, ' FROM manual_', p_table, ' m WHERE m.review_status IN (''fixed'', ''approved'')');
  CALL sp_exec();
END $$
DELIMITER ;

-- Step (1a): rows identical in every column. Keep the first, archive the rest.
-- MD5 over all columns = exact, case-sensitive fingerprint of the row.
DELIMITER $$
DROP PROCEDURE IF EXISTS sp_archive_exact_duplicates $$
CREATE PROCEDURE sp_archive_exact_duplicates(IN p_table VARCHAR(64))
BEGIN
  DECLARE v_cols TEXT;
  SELECT GROUP_CONCAT(CONCAT('`', column_name, '`') ORDER BY ordinal_position) INTO v_cols
  FROM information_schema.columns
  WHERE table_schema = DATABASE() AND table_name = CONCAT('raw_', p_table)
    AND column_name NOT IN ('raw_row_id', 'source_file', 'loaded_at');

  SET @sql = CONCAT('INSERT INTO archive_', p_table, ' (raw_row_id, ', v_cols, ', archive_reason, kept_raw_row_id) ',
    'SELECT raw_row_id, ', v_cols, ', ''exact_duplicate'', keep_id FROM (',
    '  SELECT r.*, ROW_NUMBER() OVER w AS rn, FIRST_VALUE(raw_row_id) OVER w AS keep_id',
    '  FROM raw_', p_table, ' r',
    '  WINDOW w AS (PARTITION BY MD5(CONCAT_WS(CHAR(31), ', v_cols, ')) ORDER BY raw_row_id)',
    ') d WHERE rn > 1');
  CALL sp_exec();
END $$
DELIMITER ;

-- Step (1b): same id, older updated_at -> archive the older version, keep the newest.
-- Ambiguous updated_at is read as DD/MM for this ordering only.
DELIMITER $$
DROP PROCEDURE IF EXISTS sp_archive_old_versions $$
CREATE PROCEDURE sp_archive_old_versions(IN p_table VARCHAR(64), IN p_key VARCHAR(64))
BEGIN
  DECLARE v_cols TEXT;
  SELECT GROUP_CONCAT(CONCAT('r.`', column_name, '`') ORDER BY ordinal_position) INTO v_cols
  FROM information_schema.columns
  WHERE table_schema = DATABASE() AND table_name = CONCAT('raw_', p_table)
    AND column_name NOT IN ('raw_row_id', 'source_file', 'loaded_at');

  SET @sql = CONCAT('INSERT IGNORE INTO archive_', p_table, ' (raw_row_id, ', REPLACE(v_cols, 'r.', ''), ', archive_reason, kept_raw_row_id) ',
    'SELECT r.raw_row_id, ', v_cols, ', ''superseded_version'', v.newest_row ',
    'FROM raw_', p_table, ' r JOIN (',
    '  SELECT raw_row_id, ver,',
    '         MAX(ver) OVER (PARTITION BY `', p_key, '`) AS newest_ver,',
    '         FIRST_VALUE(raw_row_id) OVER (PARTITION BY `', p_key, '` ORDER BY ver DESC) AS newest_row',
    '  FROM (SELECT raw_row_id, `', p_key, '`, COALESCE(updated_at, fn_parse_datetime(updated_at_raw, ''dmy'')) AS ver',
    '        FROM stg_', p_table, ' WHERE `', p_key, '` IS NOT NULL) x',
    ') v ON v.raw_row_id = r.raw_row_id ',
    'WHERE v.ver < v.newest_ver');
  CALL sp_exec();

  SET @sql = CONCAT('DELETE s FROM stg_', p_table, ' s JOIN archive_', p_table, ' a ON a.raw_row_id = s.raw_row_id');
  CALL sp_exec();
END $$
DELIMITER ;

-- Rule helper: value present in raw but the parser couldn't read it.
-- p_kind: 'date', 'datetime', 'money' or 'value'. Issue code says why.
DELIMITER $$
DROP PROCEDURE IF EXISTS sp_flag_unparsed $$
CREATE PROCEDURE sp_flag_unparsed(IN p_table VARCHAR(64), IN p_column VARCHAR(64),
                                  IN p_kind VARCHAR(10), IN p_severity VARCHAR(12))
BEGIN
  DECLARE v_raw VARCHAR(100);
  DECLARE v_code TEXT;
  DECLARE v_suggest TEXT;
  SET v_raw = CONCAT('s.`', p_column, '_raw`');
  IF p_kind IN ('date', 'datetime') THEN
    SET v_code = CONCAT('IF(fn_parse_datetime(', v_raw, ', ''dmy'') IS NOT NULL, ''ambiguous_date'', ''unparseable_date'')');
    SET v_suggest = CONCAT('IF(fn_parse_datetime(', v_raw, ', ''dmy'') IS NULL, NULL, CONCAT(',
       IF(p_kind = 'date', 'DATE(', '('), 'fn_parse_datetime(', v_raw, ', ''dmy'')), '' if DD/MM, or '', ',
       IF(p_kind = 'date', 'DATE(', '('), 'fn_parse_datetime(', v_raw, ', ''mdy'')), '' if MM/DD''))');
  ELSEIF p_kind = 'money' THEN
    SET v_code = CONCAT('fn_money_problem(', v_raw, ')');
    SET v_suggest = CONCAT('CASE fn_money_problem(', v_raw, ') ',
       'WHEN ''dollar_sign_vs_currency'' THEN CONCAT(fn_parse_money(REPLACE(', v_raw, ', ''$'', '''')), '' if the $ is a typo'') ',
       'WHEN ''ambiguous_thousands_or_decimal'' THEN CONCAT(REPLACE(TRIM(', v_raw, '), ''.'', ''''), '' or '', TRIM(', v_raw, ')) END');
  ELSE
    SET v_code = '''unrecognised_value''';
    SET v_suggest = 'NULL';
  END IF;

  SET @sql = CONCAT('INSERT INTO manual_issues (table_name, raw_row_id, entity_id, column_name, issue_code, severity, raw_value, suggested_value) ',
    'SELECT ''', p_table, ''', s.raw_row_id, s.entity_id, ''', p_column, ''', ', v_code, ', ''', p_severity, ''', ', v_raw, ', ', v_suggest,
    ' FROM stg_', p_table, ' s WHERE s.`', p_column, '` IS NULL AND fn_clean_text(', v_raw, ') IS NOT NULL');
  CALL sp_exec();
END $$
DELIMITER ;

-- Rule helper: required value missing.
DELIMITER $$
DROP PROCEDURE IF EXISTS sp_flag_missing $$
CREATE PROCEDURE sp_flag_missing(IN p_table VARCHAR(64), IN p_column VARCHAR(64))
BEGIN
  SET @sql = CONCAT('INSERT INTO manual_issues (table_name, raw_row_id, entity_id, column_name, issue_code, severity, raw_value) ',
    'SELECT ''', p_table, ''', raw_row_id, entity_id, ''', p_column, ''', ''missing_value'', ''hold'', `', p_column, '_raw` ',
    'FROM stg_', p_table, ' WHERE `', p_column, '` IS NULL AND fn_clean_text(`', p_column, '_raw`) IS NULL');
  CALL sp_exec();
END $$
DELIMITER ;

-- Rule helper: different rows sharing one id (after dups and old versions are archived).
-- No way to tell which is right, so all of them are held.
DELIMITER $$
DROP PROCEDURE IF EXISTS sp_flag_conflicting_duplicates $$
CREATE PROCEDURE sp_flag_conflicting_duplicates(IN p_table VARCHAR(64), IN p_key VARCHAR(64))
BEGIN
  SET @sql = CONCAT('INSERT INTO manual_issues (table_name, raw_row_id, entity_id, column_name, issue_code, severity, raw_value, detail) ',
    'SELECT ''', p_table, ''', s.raw_row_id, s.entity_id, ''', p_key, ''', ''conflicting_duplicate'', ''hold'', s.entity_id, ',
    'CONCAT(d.n, '' different rows have this id; keep one, reject the others'') ',
    'FROM stg_', p_table, ' s JOIN (SELECT `', p_key, '` AS k, COUNT(*) AS n FROM stg_', p_table,
    ' WHERE `', p_key, '` IS NOT NULL GROUP BY `', p_key, '` HAVING COUNT(*) > 1) d ON d.k = s.`', p_key, '`');
  CALL sp_exec();
END $$
DELIMITER ;

-- Rule helper for FKs. Parent id doesn't exist -> 'orphan_reference' (hold).
-- Parent exists but is held in manual_<parent> -> 'waiting_for_parent'
-- (released on the next run once the parent is fixed).
DELIMITER $$
DROP PROCEDURE IF EXISTS sp_flag_parent $$
CREATE PROCEDURE sp_flag_parent(IN p_child VARCHAR(64), IN p_fk VARCHAR(64),
                                IN p_parent VARCHAR(64), IN p_parent_key VARCHAR(64))
BEGIN
  SET @sql = CONCAT('INSERT INTO manual_issues (table_name, raw_row_id, entity_id, column_name, issue_code, severity, raw_value, detail) ',
    'SELECT ''', p_child, ''', c.raw_row_id, c.entity_id, ''', p_fk, ''', ''orphan_reference'', ''hold'', c.`', p_fk, '_raw`, ',
    'CONCAT(''no ', p_parent, ' row has id '', c.`', p_fk, '`) ',
    'FROM stg_', p_child, ' c WHERE c.`', p_fk, '` IS NOT NULL ',
    'AND NOT EXISTS (SELECT 1 FROM stg_', p_parent, ' p WHERE p.`', p_parent_key, '` = c.`', p_fk, '`)');
  CALL sp_exec();

  SET @sql = CONCAT('INSERT INTO manual_issues (table_name, raw_row_id, entity_id, column_name, issue_code, severity, raw_value, detail) ',
    'SELECT ''', p_child, ''', c.raw_row_id, c.entity_id, ''', p_fk, ''', ''waiting_for_parent'', ''waiting'', c.`', p_fk, '_raw`, ',
    'CONCAT(''', p_parent, ' '', c.`', p_fk, '`, '' is held in manual_', p_parent, ''') ',
    'FROM stg_', p_child, ' c WHERE c.`', p_fk, '` IS NOT NULL ',
    'AND EXISTS (SELECT 1 FROM stg_', p_parent, ' p WHERE p.`', p_parent_key, '` = c.`', p_fk, '`) ',
    'AND NOT EXISTS (SELECT 1 FROM stg_', p_parent, ' p WHERE p.`', p_parent_key, '` = c.`', p_fk, '` AND p.load_ok = 1) ',
    'AND NOT EXISTS (SELECT 1 FROM manual_issues i WHERE i.table_name = ''', p_child, ''' AND i.raw_row_id = c.raw_row_id AND i.column_name = ''', p_fk, ''')');
  CALL sp_exec();
END $$
DELIMITER ;

-- Steps (4) and (5) for one table, after all its rules have run:
--   a. drop judgement-call issues on rows marked 'approved'
--   b. set 'null_value' columns to NULL in stg_<t>
--   c. mark rows with a 'hold' or 'waiting' issue as not loadable
--   d. upsert flagged rows into manual_<t> (manual edits are never overwritten)
--   e. remove manual rows that are no longer a problem (untouched 'open' ones only)
--   f. insert every loadable row into airbnb_clean.<t>
DELIMITER $$
DROP PROCEDURE IF EXISTS sp_finish_table $$
CREATE PROCEDURE sp_finish_table(IN p_table VARCHAR(64))
BEGIN
  DECLARE v_names TEXT;
  DECLARE v_rcols TEXT;
  DECLARE v_clean_cols TEXT;
  DECLARE v_col VARCHAR(64);
  DECLARE done INT DEFAULT 0;
  DECLARE cur CURSOR FOR
    SELECT DISTINCT column_name FROM manual_issues WHERE table_name = p_table AND severity = 'null_value';
  DECLARE CONTINUE HANDLER FOR NOT FOUND SET done = 1;

  -- a. approval only clears issues a rule merely suspects
  SET @sql = CONCAT('DELETE i FROM manual_issues i JOIN manual_', p_table, ' m ON m.raw_row_id = i.raw_row_id ',
    'WHERE i.table_name = ''', p_table, ''' AND m.review_status = ''approved'' AND i.issue_code IN (',
    '''duplicate_guest'', ''duplicate_neighbourhood'', ''overlapping_booking'', ''junk_review'', ''amount_does_not_reconcile'',',
    '''paid_before_booked'', ''full_name_in_first_name'', ''guests_exceed_capacity'', ''price_outlier'', ''created_before_host_since'',',
    '''booking_after_check_in'', ''review_before_check_out'', ''coordinates_outside_area'', ''coordinates_swapped'')');
  CALL sp_exec();

  -- b. NULL out the doubtful values, one column at a time
  OPEN cur;
  null_loop: LOOP
    FETCH cur INTO v_col;
    IF done THEN LEAVE null_loop; END IF;
    SET @sql = CONCAT('UPDATE stg_', p_table, ' s JOIN manual_issues i ON i.raw_row_id = s.raw_row_id ',
      'SET s.`', v_col, '` = NULL ',
      'WHERE i.table_name = ''', p_table, ''' AND i.column_name = ''', v_col, ''' AND i.severity = ''null_value''');
    CALL sp_exec();
  END LOOP;
  CLOSE cur;

  -- c. held rows don't go to clean
  SET @sql = CONCAT('UPDATE stg_', p_table, ' s JOIN (SELECT DISTINCT raw_row_id FROM manual_issues ',
    'WHERE table_name = ''', p_table, ''' AND severity IN (''hold'', ''waiting'')) h ON h.raw_row_id = s.raw_row_id ',
    'SET s.load_ok = 0');
  CALL sp_exec();

  -- d. upsert into manual_<t>
  SELECT GROUP_CONCAT(CONCAT('`', column_name, '`') ORDER BY ordinal_position),
         GROUP_CONCAT(CONCAT('r.`', column_name, '`') ORDER BY ordinal_position)
    INTO v_names, v_rcols
  FROM information_schema.columns
  WHERE table_schema = DATABASE() AND table_name = CONCAT('raw_', p_table)
    AND column_name NOT IN ('raw_row_id', 'source_file', 'loaded_at');

  SET @sql = CONCAT('INSERT INTO manual_', p_table,
    ' (raw_row_id, ', v_names, ', issue_summary, suggested_fix, in_clean, needs_action, merge_into_id, first_flagged_at, last_checked_at) ',
    'SELECT r.raw_row_id, ', v_rcols, ', i.summary, i.suggestion, i.loaded, i.act, i.merge_id, NOW(), NOW() ',
    'FROM (SELECT raw_row_id, ',
    '        GROUP_CONCAT(DISTINCT issue_code ORDER BY issue_code SEPARATOR '', '') AS summary, ',
    '        GROUP_CONCAT(CASE WHEN suggested_value IS NOT NULL THEN CONCAT(column_name, '': '', suggested_value) END SEPARATOR '' | '') AS suggestion, ',
    '        MIN(severity NOT IN (''hold'', ''waiting'')) AS loaded, ',
    '        MAX(severity <> ''waiting'') AS act, ',
    '        MAX(CASE WHEN issue_code LIKE ''duplicate%'' THEN CAST(suggested_value AS UNSIGNED) END) AS merge_id ',
    '      FROM manual_issues WHERE table_name = ''', p_table, ''' GROUP BY raw_row_id) i ',
    'JOIN raw_', p_table, ' r ON r.raw_row_id = i.raw_row_id ',
    'ON DUPLICATE KEY UPDATE issue_summary = i.summary, suggested_fix = i.suggestion, in_clean = i.loaded, ',
    '  needs_action = i.act, last_checked_at = NOW(), ',
    '  merge_into_id = COALESCE(manual_', p_table, '.merge_into_id, i.merge_id), ',
    -- fixed/approved row that still fails -> back to 'open', edits kept
    '  review_status = IF(manual_', p_table, '.review_status IN (''fixed'', ''approved''), ''open'', manual_', p_table, '.review_status)');
  CALL sp_exec();

  -- e. tidy up
  SET @sql = CONCAT('DELETE m FROM manual_', p_table, ' m WHERE m.review_status = ''open'' AND NOT EXISTS ',
    '(SELECT 1 FROM manual_issues i WHERE i.table_name = ''', p_table, ''' AND i.raw_row_id = m.raw_row_id)');
  CALL sp_exec();

  -- f. load clean (columns taken from the clean table, generated columns skipped)
  SELECT GROUP_CONCAT(CONCAT('`', column_name, '`') ORDER BY ordinal_position) INTO v_clean_cols
  FROM information_schema.columns
  WHERE table_schema = 'airbnb_clean' AND table_name = p_table AND extra NOT LIKE '%GENERATED%';

  SET @sql = CONCAT('INSERT INTO airbnb_clean.', p_table, ' (', v_clean_cols, ') ',
    'SELECT ', v_clean_cols, ' FROM stg_', p_table, ' WHERE load_ok = 1');
  CALL sp_exec();
END $$
DELIMITER ;



-- #####################################################################
-- PART 2. Setup for this run
-- #####################################################################

-- 2.1 Category mapping. Key = lower-cased, trimmed raw value.
-- utf8mb4_0900_ai_ci ignores case and accents, so 'espana' matches 'España'.
-- New unmapped values show up in manual_issues as 'unrecognised_value', add them here.
DROP TABLE IF EXISTS map_values;
CREATE TABLE map_values (
  domain     VARCHAR(30)  NOT NULL,
  raw_value  VARCHAR(100) NOT NULL,
  canonical  VARCHAR(60)  NOT NULL,
  PRIMARY KEY (domain, raw_value)
);

INSERT INTO map_values (domain, raw_value, canonical) VALUES
  -- room_type
  ('room_type','entire_home','entire_home'), ('room_type','entire home/apt','entire_home'), ('room_type','entire home','entire_home'),
  ('room_type','entire place','entire_home'), ('room_type','private_room','private_room'), ('room_type','private room','private_room'),
  ('room_type','private','private_room'), ('room_type','shared_room','shared_room'), ('room_type','shared room','shared_room'),
  ('room_type','shared-room','shared_room'), ('room_type','shared','shared_room'), ('room_type','hotel_room','hotel_room'),
  ('room_type','hotel room','hotel_room'), ('room_type','hotel','hotel_room'),
  -- property_type
  ('property_type','apartment','apartment'), ('property_type','apt','apartment'), ('property_type','flat','apartment'),
  ('property_type','apartmnt','apartment'), ('property_type','house','house'), ('property_type','home','house'),
  ('property_type','entire house','house'), ('property_type','condo','condo'), ('property_type','condominium','condo'),
  ('property_type','loft','loft'), ('property_type','townhouse','townhouse'), ('property_type','town house','townhouse'),
  ('property_type','town-house','townhouse'), ('property_type','studio','studio'), ('property_type','studio flat','studio'),
  ('property_type','guest_suite','guest_suite'), ('property_type','guest suite','guest_suite'), ('property_type','guest-suite','guest_suite'),
  ('property_type','guestsuite','guest_suite'), ('property_type','villa','villa'), ('property_type','boat','boat'),
  ('property_type','houseboat','boat'), ('property_type','house boat','boat'),
  -- listing status
  ('listing_status','active','active'), ('listing_status','live','active'), ('listing_status','inactive','inactive'),
  ('listing_status','paused','inactive'), ('listing_status','in-active','inactive'), ('listing_status','delisted','delisted'),
  ('listing_status','removed','delisted'), ('listing_status','de-listed','delisted'),
  -- booking status
  ('booking_status','completed','completed'), ('booking_status','complete','completed'), ('booking_status','done','completed'),
  ('booking_status','cancelled','cancelled'), ('booking_status','canceled','cancelled'), ('booking_status','canceled by guest','cancelled'),
  ('booking_status','confirmed','confirmed'), ('booking_status','confirmd','confirmed'), ('booking_status','conf','confirmed'),
  ('booking_status','no_show','no_show'), ('booking_status','no-show','no_show'), ('booking_status','noshow','no_show'),
  ('booking_status','no show','no_show'),
  -- channel
  ('channel','web','web'), ('channel','website','web'), ('channel','www','web'), ('channel','ios','ios'), ('channel','iphone','ios'),
  ('channel','apple','ios'), ('channel','android','android'), ('channel','andriod','android'), ('channel','partner_api','partner_api'),
  ('channel','api','partner_api'), ('channel','partner','partner_api'), ('channel','partner api','partner_api'),
  -- payment method
  ('payment_method','credit_card','credit_card'), ('payment_method','credit card','credit_card'), ('payment_method','cc','credit_card'),
  ('payment_method','visa','credit_card'), ('payment_method','mastercard','credit_card'), ('payment_method','debit_card','debit_card'),
  ('payment_method','debit card','debit_card'), ('payment_method','debit','debit_card'), ('payment_method','paypal','paypal'),
  ('payment_method','pay pal','paypal'), ('payment_method','apple_pay','apple_pay'), ('payment_method','apple pay','apple_pay'),
  ('payment_method','applepay','apple_pay'), ('payment_method','google_pay','google_pay'), ('payment_method','google pay','google_pay'),
  ('payment_method','gpay','google_pay'), ('payment_method','googlepay','google_pay'), ('payment_method','bank_transfer','bank_transfer'),
  ('payment_method','bank transfer','bank_transfer'), ('payment_method','wire','bank_transfer'), ('payment_method','sepa','bank_transfer'),
  ('payment_method','bank','bank_transfer'),
  -- payment status
  ('payment_status','completed','completed'), ('payment_status','complete','completed'), ('payment_status','success','completed'),
  ('payment_status','paid','completed'), ('payment_status','refunded','refunded'), ('payment_status','refund','refunded'),
  ('payment_status','failed','failed'), ('payment_status','declined','failed'), ('payment_status','error','failed'),
  ('payment_status','pending','pending'), ('payment_status','processing','pending'), ('payment_status','in progress','pending'),
  -- gender
  ('gender','female','female'), ('gender','f','female'), ('gender','w','female'), ('gender','woman','female'),
  ('gender','male','male'), ('gender','m','male'), ('gender','man','male'),
  ('gender','non_binary','non_binary'), ('gender','non-binary','non_binary'), ('gender','non binary','non_binary'),
  ('gender','nb','non_binary'), ('gender','x','non_binary'),
  ('gender','undisclosed','undisclosed'), ('gender','prefer not to say','undisclosed'), ('gender','unknown','undisclosed'),
  ('gender','u','undisclosed'), ('gender','?','undisclosed'),
  -- currency
  ('currency','gbp','GBP'), ('currency','£','GBP'), ('currency','pound','GBP'), ('currency','ukp','GBP'),
  ('currency','eur','EUR'), ('currency','€','EUR'), ('currency','euro','EUR'), ('currency','euros','EUR'),
  -- city
  ('city','london','London'), ('city','londres','London'), ('city','paris','Paris'), ('city','barcelona','Barcelona'),
  ('city','bcn','Barcelona'), ('city','barcelone','Barcelona'), ('city','amsterdam','Amsterdam'), ('city','ams','Amsterdam'),
  -- country
  ('country','united kingdom','United Kingdom'), ('country','uk','United Kingdom'), ('country','u.k.','United Kingdom'),
  ('country','gb','United Kingdom'), ('country','great britain','United Kingdom'), ('country','england','United Kingdom'),
  ('country','france','France'), ('country','fr','France'), ('country','frankreich','France'),
  ('country','spain','Spain'), ('country','es','Spain'), ('country','espana','Spain'),
  ('country','netherlands','Netherlands'), ('country','nl','Netherlands'), ('country','holland','Netherlands'),
  ('country','the netherlands','Netherlands'),
  ('country','germany','Germany'), ('country','de','Germany'), ('country','deutschland','Germany'),
  ('country','united states','United States'), ('country','usa','United States'), ('country','us','United States'),
  ('country','u.s.a.','United States'), ('country','america','United States'),
  ('country','italy','Italy'), ('country','it','Italy'), ('country','italia','Italy'),
  ('country','ireland','Ireland'), ('country','ie','Ireland'), ('country','eire','Ireland'),
  ('country','poland','Poland'), ('country','pl','Poland'), ('country','polska','Poland'),
  ('country','portugal','Portugal'), ('country','pt','Portugal'),
  ('country','canada','Canada'), ('country','ca','Canada'),
  ('country','australia','Australia'), ('country','au','Australia'), ('country','aus','Australia'),
  ('country','sweden','Sweden'), ('country','se','Sweden'), ('country','sverige','Sweden');

-- 2.2 archive_<t>, manual_<t> (kept between runs) and the src_<t> views
CALL sp_setup_table('neighbourhoods');
CALL sp_setup_table('hosts');
CALL sp_setup_table('guests');
CALL sp_setup_table('amenities');
CALL sp_setup_table('listings');
CALL sp_setup_table('listing_amenities');
CALL sp_setup_table('bookings');
CALL sp_setup_table('payments');
CALL sp_setup_table('reviews');

-- 2.3 Archive is derived from raw, rebuilt every run.
TRUNCATE TABLE archive_neighbourhoods;  TRUNCATE TABLE archive_hosts;     TRUNCATE TABLE archive_guests;
TRUNCATE TABLE archive_amenities;       TRUNCATE TABLE archive_listings;  TRUNCATE TABLE archive_listing_amenities;
TRUNCATE TABLE archive_bookings;        TRUNCATE TABLE archive_payments;  TRUNCATE TABLE archive_reviews;

-- 2.4 One row per problem found in this run (rebuilt every run).
DROP TABLE IF EXISTS manual_issues;
CREATE TABLE manual_issues (
  issue_id         BIGINT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
  table_name       VARCHAR(30)  NOT NULL,
  raw_row_id       BIGINT UNSIGNED NOT NULL,     -- joins to raw_<t>, manual_<t>
  entity_id        VARCHAR(60)  NULL,            -- the business id as written in raw (booking_id, ...)
  column_name      VARCHAR(30)  NOT NULL,
  issue_code       VARCHAR(40)  NOT NULL,
  severity         ENUM('hold', 'null_value', 'keep_value', 'waiting') NOT NULL,
  raw_value        TEXT         NULL,
  detail           VARCHAR(255) NULL,
  suggested_value  VARCHAR(255) NULL,
  detected_at      TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP,
  KEY ix_issues_row (table_name, raw_row_id),
  KEY ix_issues_col (table_name, column_name, severity)
);

-- 2.5 Empty the clean tables (countries/cities lookups stay). FK checks off only for
-- the TRUNCATEs, MySQL won't truncate a parent table otherwise.
SET FOREIGN_KEY_CHECKS = 0;
TRUNCATE TABLE airbnb_clean.reviews;   TRUNCATE TABLE airbnb_clean.payments;  TRUNCATE TABLE airbnb_clean.bookings;
TRUNCATE TABLE airbnb_clean.listing_amenities; TRUNCATE TABLE airbnb_clean.listings;
TRUNCATE TABLE airbnb_clean.amenities; TRUNCATE TABLE airbnb_clean.guests;    TRUNCATE TABLE airbnb_clean.hosts;
TRUNCATE TABLE airbnb_clean.neighbourhoods;
SET FOREIGN_KEY_CHECKS = 1;


-- #####################################################################
-- PART 3. Table by table, same steps each time:
--   archive exact duplicates -> build stg_<t> -> (archive old versions) -> rules -> sp_finish_table
-- In stg_<t>, `email` is the cleaned value and `email_raw` the original text.
-- #####################################################################

-- =====================================================================
-- 3.1 NEIGHBOURHOODS
-- =====================================================================
CALL sp_archive_exact_duplicates('neighbourhoods');

DROP TABLE IF EXISTS stg_neighbourhoods;
CREATE TABLE stg_neighbourhoods AS
SELECT s.raw_row_id,
       TRIM(s.neighbourhood_id)                                  AS entity_id,
       fn_parse_id(s.neighbourhood_id)                           AS neighbourhood_id,
       fn_title_case(fn_clean_text(s.neighbourhood_name), 'place') AS neighbourhood_name,
       fn_map('city', s.city)                                    AS city,
       CAST(fn_parse_number(s.latitude) AS DECIMAL(9,6))         AS latitude,
       CAST(fn_parse_number(s.longitude) AS DECIMAL(9,6))        AS longitude,
       s.neighbourhood_id AS neighbourhood_id_raw, s.neighbourhood_name AS neighbourhood_name_raw,
       s.city AS city_raw, s.latitude AS latitude_raw, s.longitude AS longitude_raw,
       1 AS load_ok
FROM src_neighbourhoods s;
ALTER TABLE stg_neighbourhoods ADD PRIMARY KEY (raw_row_id), ADD INDEX (neighbourhood_id);

CALL sp_flag_missing('neighbourhoods', 'neighbourhood_id');
CALL sp_flag_unparsed('neighbourhoods', 'neighbourhood_id', 'value', 'hold');
CALL sp_flag_conflicting_duplicates('neighbourhoods', 'neighbourhood_id');
CALL sp_flag_missing('neighbourhoods', 'neighbourhood_name');
CALL sp_flag_missing('neighbourhoods', 'city');
CALL sp_flag_unparsed('neighbourhoods', 'city', 'value', 'hold');
CALL sp_flag_missing('neighbourhoods', 'latitude');
CALL sp_flag_missing('neighbourhoods', 'longitude');

-- Same neighbourhood under a new id: same city, centre within ~1 km, AND same name
-- (ignoring case/accents: 'Gracia' = 'Gràcia') or one name starting with the other
-- ('Camden Town' / 'Camden'). Distance alone isn't enough, some real neighbourhood
-- centres are only 100 m apart.
-- Newer id is held, older id suggested as the merge target.
INSERT INTO manual_issues (table_name, raw_row_id, entity_id, column_name, issue_code, severity, raw_value, detail, suggested_value)
SELECT 'neighbourhoods', d.raw_row_id, d.entity_id, 'neighbourhood_id', 'duplicate_neighbourhood', 'hold',
       d.neighbourhood_name_raw,
       CONCAT('looks like ', ANY_VALUE(o.neighbourhood_name), ' (id ', MIN(o.neighbourhood_id), ')'),
       CAST(MIN(o.neighbourhood_id) AS CHAR)
FROM stg_neighbourhoods d
JOIN stg_neighbourhoods o
  ON o.city = d.city
 AND o.neighbourhood_id < d.neighbourhood_id
 AND ABS(o.latitude - d.latitude) < 0.01 AND ABS(o.longitude - d.longitude) < 0.01
 AND (o.neighbourhood_name = d.neighbourhood_name
      OR d.neighbourhood_name LIKE CONCAT(o.neighbourhood_name, ' %')
      OR o.neighbourhood_name LIKE CONCAT(d.neighbourhood_name, ' %'))
GROUP BY d.raw_row_id, d.entity_id, d.neighbourhood_name_raw;

CALL sp_finish_table('neighbourhoods');

-- Merges confirmed in manual_neighbourhoods (review_status = 'merged').
DROP TABLE IF EXISTS map_neighbourhood_merge;
CREATE TABLE map_neighbourhood_merge (old_id INT UNSIGNED PRIMARY KEY, new_id INT UNSIGNED NOT NULL)
SELECT fn_parse_id(neighbourhood_id) AS old_id, merge_into_id AS new_id
FROM manual_neighbourhoods
WHERE review_status = 'merged' AND merge_into_id IS NOT NULL AND fn_parse_id(neighbourhood_id) IS NOT NULL;


-- =====================================================================
-- 3.2 HOSTS
-- =====================================================================
CALL sp_archive_exact_duplicates('hosts');

DROP TABLE IF EXISTS stg_hosts;
CREATE TABLE stg_hosts AS
SELECT d.*,
       fn_phone_e164(d.phone_raw, c.calling_code) AS phone,
       c.calling_code, c.phone_national_len,
       1 AS load_ok
FROM (
  SELECT s.raw_row_id,
         TRIM(s.host_id)                                    AS entity_id,
         fn_parse_id(s.host_id)                             AS host_id,
         fn_title_case(fn_clean_text(s.first_name), 'person') AS first_name,
         fn_title_case(fn_clean_text(s.last_name), 'person')  AS last_name,
         LOWER(fn_clean_text(s.email))                      AS email,
         fn_map('country', s.country)                       AS country,
         DATE(fn_parse_datetime(s.host_since, 'strict'))    AS host_since,
         fn_parse_bool(s.is_superhost)                      AS is_superhost,
         fn_parse_percent(s.response_rate)                  AS response_rate,
         fn_parse_bool(s.identity_verified)                 AS identity_verified,
         fn_parse_datetime(s.updated_at, 'strict')          AS updated_at,
         s.host_id AS host_id_raw, s.first_name AS first_name_raw, s.last_name AS last_name_raw, s.email AS email_raw,
         s.phone AS phone_raw, s.country AS country_raw, s.host_since AS host_since_raw,
         s.is_superhost AS is_superhost_raw, s.response_rate AS response_rate_raw,
         s.identity_verified AS identity_verified_raw, s.updated_at AS updated_at_raw
  FROM src_hosts s
) d
LEFT JOIN airbnb_clean.countries c ON c.country_name = d.country;
ALTER TABLE stg_hosts ADD PRIMARY KEY (raw_row_id), ADD INDEX (host_id);

-- Older versions of the same host (older updated_at) -> archive.
CALL sp_archive_old_versions('hosts', 'host_id');

CALL sp_flag_missing('hosts', 'host_id');
CALL sp_flag_unparsed('hosts', 'host_id', 'value', 'hold');
CALL sp_flag_conflicting_duplicates('hosts', 'host_id');
CALL sp_flag_missing('hosts', 'first_name');
CALL sp_flag_unparsed('hosts', 'country', 'value', 'null_value');
CALL sp_flag_unparsed('hosts', 'host_since', 'date', 'null_value');
CALL sp_flag_missing('hosts', 'is_superhost');
CALL sp_flag_unparsed('hosts', 'is_superhost', 'value', 'hold');
CALL sp_flag_unparsed('hosts', 'response_rate', 'value', 'null_value');
CALL sp_flag_missing('hosts', 'identity_verified');
CALL sp_flag_unparsed('hosts', 'identity_verified', 'value', 'hold');
CALL sp_flag_unparsed('hosts', 'updated_at', 'datetime', 'null_value');

-- Business rules
INSERT INTO manual_issues (table_name, raw_row_id, entity_id, column_name, issue_code, severity, raw_value)
SELECT 'hosts', raw_row_id, entity_id, 'email', 'invalid_email', 'null_value', email_raw
FROM stg_hosts WHERE email IS NOT NULL AND NOT fn_is_valid_email(email);

INSERT INTO manual_issues (table_name, raw_row_id, entity_id, column_name, issue_code, severity, raw_value)
SELECT 'hosts', raw_row_id, entity_id, 'phone', 'invalid_phone', 'null_value', phone_raw
FROM stg_hosts
WHERE phone IS NOT NULL
  AND NOT (REGEXP_LIKE(phone, '^[+][0-9]+$')
           AND phone LIKE CONCAT('+', calling_code, '%')
           AND CHAR_LENGTH(phone) = 1 + CHAR_LENGTH(calling_code) + phone_national_len);

INSERT INTO manual_issues (table_name, raw_row_id, entity_id, column_name, issue_code, severity, raw_value)
SELECT 'hosts', raw_row_id, entity_id, 'host_since', 'date_in_future', 'null_value', host_since_raw
FROM stg_hosts WHERE host_since > @snapshot_date;

INSERT INTO manual_issues (table_name, raw_row_id, entity_id, column_name, issue_code, severity, raw_value)
SELECT 'hosts', raw_row_id, entity_id, 'response_rate', 'percent_over_100', 'null_value', response_rate_raw
FROM stg_hosts WHERE response_rate > 100;

INSERT INTO manual_issues (table_name, raw_row_id, entity_id, column_name, issue_code, severity, raw_value, suggested_value)
SELECT 'hosts', raw_row_id, entity_id, 'first_name', 'full_name_in_first_name', 'keep_value', first_name_raw,
       CONCAT('first_name=', SUBSTRING_INDEX(first_name, ' ', 1), ', last_name=', SUBSTRING(first_name, LOCATE(' ', first_name) + 1))
FROM stg_hosts WHERE last_name IS NULL AND LOCATE(' ', first_name) > 0;

-- Two hosts with one e-mail: typo or a couple sharing an inbox, so the value is kept
-- and flagged. The host whose surname is in the address is taken as the owner.
INSERT INTO manual_issues (table_name, raw_row_id, entity_id, column_name, issue_code, severity, raw_value, detail)
SELECT 'hosts', raw_row_id, entity_id, 'email', 'email_used_by_other_host', 'keep_value', email_raw,
       CONCAT('same e-mail as host ', first_host)
FROM (
  SELECT raw_row_id, entity_id, email_raw, host_id,
         ROW_NUMBER() OVER w AS rn, FIRST_VALUE(host_id) OVER w AS first_host
  FROM stg_hosts
  WHERE email IS NOT NULL AND fn_is_valid_email(email)
  WINDOW w AS (PARTITION BY email
               ORDER BY LOCATE(REPLACE(REPLACE(LOWER(COALESCE(last_name, first_name)), ' ', ''), '''', ''), email) > 0 DESC,
                        host_id)
) x
WHERE rn > 1 AND first_host <> host_id;

CALL sp_finish_table('hosts');


-- =====================================================================
-- 3.3 GUESTS
-- =====================================================================
CALL sp_archive_exact_duplicates('guests');

DROP TABLE IF EXISTS stg_guests;
CREATE TABLE stg_guests AS
SELECT d.*,
       fn_phone_e164(d.phone_raw, c.calling_code) AS phone,
       c.calling_code, c.phone_national_len,
       1 AS load_ok
FROM (
  SELECT s.raw_row_id,
         TRIM(s.guest_id)                                    AS entity_id,
         fn_parse_id(s.guest_id)                             AS guest_id,
         fn_title_case(fn_clean_text(s.first_name), 'person') AS first_name,
         fn_title_case(fn_clean_text(s.last_name), 'person')  AS last_name,
         LOWER(fn_clean_text(s.email))                       AS email,
         fn_map('gender', s.gender)                          AS gender,
         DATE(fn_parse_datetime(s.date_of_birth, 'strict'))  AS date_of_birth,
         fn_map('country', s.country)                        AS country,
         DATE(fn_parse_datetime(s.signup_date, 'strict'))    AS signup_date,
         s.guest_id AS guest_id_raw, s.first_name AS first_name_raw, s.last_name AS last_name_raw,
         s.email AS email_raw, s.phone AS phone_raw, s.gender AS gender_raw,
         s.date_of_birth AS date_of_birth_raw, s.country AS country_raw, s.signup_date AS signup_date_raw
  FROM src_guests s
) d
LEFT JOIN airbnb_clean.countries c ON c.country_name = d.country;
ALTER TABLE stg_guests ADD PRIMARY KEY (raw_row_id), ADD INDEX (guest_id);

CALL sp_flag_missing('guests', 'guest_id');
CALL sp_flag_unparsed('guests', 'guest_id', 'value', 'hold');
CALL sp_flag_conflicting_duplicates('guests', 'guest_id');
CALL sp_flag_missing('guests', 'first_name');
CALL sp_flag_unparsed('guests', 'gender', 'value', 'null_value');
CALL sp_flag_unparsed('guests', 'country', 'value', 'null_value');
CALL sp_flag_unparsed('guests', 'date_of_birth', 'date', 'null_value');
CALL sp_flag_unparsed('guests', 'signup_date', 'date', 'null_value');

INSERT INTO manual_issues (table_name, raw_row_id, entity_id, column_name, issue_code, severity, raw_value)
SELECT 'guests', raw_row_id, entity_id, 'email', 'invalid_email', 'null_value', email_raw
FROM stg_guests WHERE email IS NOT NULL AND NOT fn_is_valid_email(email);

INSERT INTO manual_issues (table_name, raw_row_id, entity_id, column_name, issue_code, severity, raw_value)
SELECT 'guests', raw_row_id, entity_id, 'phone', 'invalid_phone', 'null_value', phone_raw
FROM stg_guests
WHERE phone IS NOT NULL
  AND NOT (REGEXP_LIKE(phone, '^[+][0-9]+$')
           AND phone LIKE CONCAT('+', calling_code, '%')
           AND CHAR_LENGTH(phone) = 1 + CHAR_LENGTH(calling_code) + phone_national_len);

INSERT INTO manual_issues (table_name, raw_row_id, entity_id, column_name, issue_code, severity, raw_value)
SELECT 'guests', raw_row_id, entity_id, 'date_of_birth',
       IF(date_of_birth > @snapshot_date, 'date_in_future', 'age_under_18'), 'null_value', date_of_birth_raw
FROM stg_guests WHERE date_of_birth > @snapshot_date - INTERVAL 18 YEAR;

INSERT INTO manual_issues (table_name, raw_row_id, entity_id, column_name, issue_code, severity, raw_value)
SELECT 'guests', raw_row_id, entity_id, 'date_of_birth', 'age_over_110', 'null_value', date_of_birth_raw
FROM stg_guests WHERE date_of_birth < @snapshot_date - INTERVAL 110 YEAR;

INSERT INTO manual_issues (table_name, raw_row_id, entity_id, column_name, issue_code, severity, raw_value)
SELECT 'guests', raw_row_id, entity_id, 'signup_date', 'date_in_future', 'null_value', signup_date_raw
FROM stg_guests WHERE signup_date > @snapshot_date;

-- Probable duplicate accounts. Three match keys:
--   1. same e-mail (ignoring case, dots and +alias, gmail style) + same phone
--   2. same first name + last name + date of birth
--   3. same first name + last name + phone
-- E-mail alone isn't enough: two different 'James Smith's both use james.smith@gmail.com
-- in this data. Those get 'email_used_by_other_guest' further down.
-- Lowest guest_id in a group survives, the others are held with it as merge_into_id.
-- Bookings get remapped once the merge is confirmed.
DROP TABLE IF EXISTS tmp_guest_match;
CREATE TABLE tmp_guest_match AS
SELECT raw_row_id, entity_id, guest_id,
       CASE WHEN email_key IS NOT NULL THEN MIN(guest_id) OVER (PARTITION BY email_key) END      AS by_email,
       CASE WHEN name_dob_key IS NOT NULL THEN MIN(guest_id) OVER (PARTITION BY name_dob_key) END AS by_name_dob,
       CASE WHEN name_phone_key IS NOT NULL THEN MIN(guest_id) OVER (PARTITION BY name_phone_key) END AS by_name_phone
FROM (
  SELECT raw_row_id, entity_id, guest_id,
         CASE WHEN fn_is_valid_email(email) AND CHAR_LENGTH(phone) = 1 + CHAR_LENGTH(calling_code) + phone_national_len THEN
              CONCAT(REPLACE(SUBSTRING_INDEX(SUBSTRING_INDEX(email, '@', 1), '+', 1), '.', ''), '@', SUBSTRING_INDEX(email, '@', -1),
                     '|', phone)
         END AS email_key,
         CASE WHEN date_of_birth IS NOT NULL THEN CONCAT_WS('|', first_name, last_name, date_of_birth) END AS name_dob_key,
         CASE WHEN CHAR_LENGTH(phone) = 1 + CHAR_LENGTH(calling_code) + phone_national_len
              THEN CONCAT_WS('|', first_name, last_name, phone) END AS name_phone_key
  FROM stg_guests
  WHERE guest_id IS NOT NULL
) k;

INSERT INTO manual_issues (table_name, raw_row_id, entity_id, column_name, issue_code, severity, raw_value, detail, suggested_value)
SELECT 'guests', raw_row_id, entity_id, 'guest_id', 'duplicate_guest', 'hold', entity_id,
       CONCAT('probably the same person as guest ', survivor, ': ',
              CONCAT_WS(', ', IF(by_email < guest_id, 'same e-mail and phone', NULL),
                              IF(by_name_dob < guest_id, 'same name and birth date', NULL),
                              IF(by_name_phone < guest_id, 'same name and phone', NULL))),
       CAST(survivor AS CHAR)
FROM (SELECT t.*, LEAST(COALESCE(by_email, guest_id), COALESCE(by_name_dob, guest_id), COALESCE(by_name_phone, guest_id)) AS survivor
      FROM tmp_guest_match t) x
WHERE survivor < guest_id;

-- Different people (not duplicates) sharing one e-mail. Kept, but flagged.
INSERT INTO manual_issues (table_name, raw_row_id, entity_id, column_name, issue_code, severity, raw_value, detail)
SELECT 'guests', raw_row_id, entity_id, 'email', 'email_used_by_other_guest', 'keep_value', email_raw,
       CONCAT('same e-mail as guest ', first_guest)
FROM (SELECT g.raw_row_id, g.entity_id, g.email_raw, g.guest_id,
             ROW_NUMBER() OVER w AS rn, FIRST_VALUE(g.guest_id) OVER w AS first_guest
      FROM stg_guests g
      WHERE g.email IS NOT NULL AND fn_is_valid_email(g.email)
        AND NOT EXISTS (SELECT 1 FROM manual_issues i WHERE i.table_name = 'guests' AND i.raw_row_id = g.raw_row_id
                        AND i.issue_code = 'duplicate_guest')
      WINDOW w AS (PARTITION BY g.email ORDER BY g.guest_id)) x
WHERE rn > 1 AND first_guest <> guest_id;

CALL sp_finish_table('guests');

DROP TABLE IF EXISTS map_guest_merge;
CREATE TABLE map_guest_merge (old_id INT UNSIGNED PRIMARY KEY, new_id INT UNSIGNED NOT NULL)
SELECT fn_parse_id(guest_id) AS old_id, merge_into_id AS new_id
FROM manual_guests
WHERE review_status = 'merged' AND merge_into_id IS NOT NULL AND fn_parse_id(guest_id) IS NOT NULL;


-- =====================================================================
-- 3.4 AMENITIES (a small dictionary with a few duplicate spellings)
-- =====================================================================
CALL sp_archive_exact_duplicates('amenities');

DROP TABLE IF EXISTS stg_amenities;
CREATE TABLE stg_amenities AS
SELECT s.raw_row_id,
       TRIM(s.amenity_id)                 AS entity_id,
       fn_parse_id(s.amenity_id)          AS amenity_id,
       fn_clean_text(s.amenity_name)      AS amenity_name,
       LOWER(fn_clean_text(s.category))   AS category,
       -- 'WiFi', 'wi-fi' and 'Wifi' all give the key 'wifi'
       LOWER(REGEXP_REPLACE(s.amenity_name, '[^a-z0-9]', '')) AS name_key,
       s.amenity_id AS amenity_id_raw, s.amenity_name AS amenity_name_raw, s.category AS category_raw,
       1 AS load_ok
FROM src_amenities s;
ALTER TABLE stg_amenities ADD PRIMARY KEY (raw_row_id), ADD INDEX (amenity_id);

-- Lookup for listing_amenities: any amenity id or name -> the id that's kept (lowest).
DROP TABLE IF EXISTS map_amenity;
CREATE TABLE map_amenity (raw_key VARCHAR(100) PRIMARY KEY, amenity_id SMALLINT UNSIGNED NOT NULL)
SELECT DISTINCT CAST(a.amenity_id AS CHAR) AS raw_key, k.keep_id AS amenity_id
FROM stg_amenities a
JOIN (SELECT name_key, MIN(amenity_id) AS keep_id FROM stg_amenities WHERE amenity_id IS NOT NULL GROUP BY name_key) k
  ON k.name_key = a.name_key
WHERE a.amenity_id IS NOT NULL
UNION
SELECT name_key, MIN(amenity_id) FROM stg_amenities WHERE amenity_id IS NOT NULL GROUP BY name_key;

-- Duplicate spellings go to the archive (their id is mapped, not lost).
INSERT INTO archive_amenities (raw_row_id, amenity_id, amenity_name, category, archive_reason, kept_raw_row_id)
SELECT r.raw_row_id, r.amenity_id, r.amenity_name, r.category, 'duplicate_dictionary_entry',
       (SELECT k.raw_row_id FROM stg_amenities k WHERE k.amenity_id = m.amenity_id LIMIT 1)
FROM stg_amenities a
JOIN map_amenity m ON m.raw_key = CAST(a.amenity_id AS CHAR)
JOIN raw_amenities r ON r.raw_row_id = a.raw_row_id
WHERE m.amenity_id <> a.amenity_id;
DELETE s FROM stg_amenities s JOIN archive_amenities a ON a.raw_row_id = s.raw_row_id;

CALL sp_flag_missing('amenities', 'amenity_id');
CALL sp_flag_unparsed('amenities', 'amenity_id', 'value', 'hold');
CALL sp_flag_conflicting_duplicates('amenities', 'amenity_id');
CALL sp_flag_missing('amenities', 'amenity_name');

CALL sp_finish_table('amenities');


-- =====================================================================
-- 3.5 LISTINGS
-- =====================================================================
CALL sp_archive_exact_duplicates('listings');

DROP TABLE IF EXISTS stg_listings;
CREATE TABLE stg_listings AS
SELECT s.raw_row_id,
       TRIM(s.listing_id)                                          AS entity_id,
       fn_parse_id(s.listing_id)                                   AS listing_id,
       fn_parse_id(s.host_id)                                      AS host_id,
       COALESCE(nm.new_id, fn_parse_id(s.neighbourhood_id))        AS neighbourhood_id,   -- confirmed merges applied
       fn_fix_text(s.title)                                        AS title,
       fn_map('property_type', s.property_type)                    AS property_type,
       fn_map('room_type', s.room_type)                            AS room_type,
       CAST(fn_parse_number(s.accommodates) AS SIGNED)             AS accommodates,
       CAST(fn_parse_number(s.bedrooms) AS SIGNED)                 AS bedrooms,
       CAST(fn_parse_number(s.bathrooms) AS DECIMAL(3,1))          AS bathrooms,
       fn_parse_money(s.price)                                     AS price,
       fn_map('currency', s.currency)                              AS currency,
       fn_parse_money(s.cleaning_fee)                              AS cleaning_fee,
       CAST(fn_parse_number(s.minimum_nights) AS SIGNED)           AS minimum_nights,
       CAST(fn_parse_number(s.maximum_nights) AS SIGNED)           AS maximum_nights,
       CAST(fn_parse_number(s.latitude) AS DECIMAL(9,6))           AS latitude,
       CAST(fn_parse_number(s.longitude) AS DECIMAL(9,6))          AS longitude,
       0                                                           AS coords_imputed,
       fn_parse_bool(s.instant_bookable)                           AS instant_bookable,
       fn_map('listing_status', s.status)                          AS status,
       DATE(fn_parse_datetime(s.created_at, 'strict'))             AS created_at,
       fn_parse_datetime(s.updated_at, 'strict')                   AS updated_at,
       s.listing_id AS listing_id_raw, s.host_id AS host_id_raw, s.neighbourhood_id AS neighbourhood_id_raw,
       s.title AS title_raw, s.property_type AS property_type_raw, s.room_type AS room_type_raw,
       s.accommodates AS accommodates_raw, s.bedrooms AS bedrooms_raw, s.bathrooms AS bathrooms_raw,
       s.price AS price_raw, s.currency AS currency_raw, s.cleaning_fee AS cleaning_fee_raw,
       s.minimum_nights AS minimum_nights_raw, s.maximum_nights AS maximum_nights_raw,
       s.latitude AS latitude_raw, s.longitude AS longitude_raw, s.instant_bookable AS instant_bookable_raw,
       s.status AS status_raw, s.created_at AS created_at_raw, s.updated_at AS updated_at_raw,
       1 AS load_ok
FROM src_listings s
LEFT JOIN map_neighbourhood_merge nm ON nm.old_id = fn_parse_id(s.neighbourhood_id);
ALTER TABLE stg_listings ADD PRIMARY KEY (raw_row_id), ADD INDEX (listing_id), ADD INDEX (host_id),
      MODIFY coords_imputed TINYINT NOT NULL;

CALL sp_archive_old_versions('listings', 'listing_id');

-- Auto-fixes that need another table:
-- (a) missing currency -> the currency of the listing's city
UPDATE stg_listings l
JOIN airbnb_clean.neighbourhoods n ON n.neighbourhood_id = l.neighbourhood_id
JOIN airbnb_clean.cities c ON c.city = n.city
SET l.currency = c.currency
WHERE l.currency IS NULL AND fn_clean_text(l.currency_raw) IS NULL;
-- (b) missing coordinates -> the neighbourhood centre (flagged with coords_imputed = 1)
UPDATE stg_listings l
JOIN airbnb_clean.neighbourhoods n ON n.neighbourhood_id = l.neighbourhood_id
SET l.latitude = n.latitude, l.longitude = n.longitude, l.coords_imputed = 1
WHERE fn_clean_text(l.latitude_raw) IS NULL AND fn_clean_text(l.longitude_raw) IS NULL;
-- (c) a lower-cased title loses the neighbourhood's capitals ('in le marais') -> put them back
UPDATE stg_listings l
JOIN airbnb_clean.neighbourhoods n ON n.neighbourhood_id = l.neighbourhood_id
SET l.title = CONCAT(LEFT(l.title, CHAR_LENGTH(l.title) - CHAR_LENGTH(n.neighbourhood_name)), n.neighbourhood_name)
WHERE l.title LIKE CONCAT('% in ', n.neighbourhood_name);

CALL sp_flag_missing('listings', 'listing_id');
CALL sp_flag_unparsed('listings', 'listing_id', 'value', 'hold');
CALL sp_flag_conflicting_duplicates('listings', 'listing_id');
CALL sp_flag_missing('listings', 'host_id');
CALL sp_flag_unparsed('listings', 'host_id', 'value', 'hold');
CALL sp_flag_missing('listings', 'neighbourhood_id');
CALL sp_flag_unparsed('listings', 'neighbourhood_id', 'value', 'hold');
CALL sp_flag_missing('listings', 'title');
CALL sp_flag_missing('listings', 'property_type');
CALL sp_flag_unparsed('listings', 'property_type', 'value', 'hold');
CALL sp_flag_missing('listings', 'room_type');
CALL sp_flag_unparsed('listings', 'room_type', 'value', 'hold');
CALL sp_flag_missing('listings', 'status');
CALL sp_flag_unparsed('listings', 'status', 'value', 'hold');
CALL sp_flag_missing('listings', 'instant_bookable');
CALL sp_flag_unparsed('listings', 'instant_bookable', 'value', 'hold');
CALL sp_flag_missing('listings', 'currency');
CALL sp_flag_unparsed('listings', 'currency', 'value', 'hold');
CALL sp_flag_unparsed('listings', 'accommodates', 'value', 'null_value');
CALL sp_flag_unparsed('listings', 'bedrooms', 'value', 'null_value');
CALL sp_flag_unparsed('listings', 'bathrooms', 'value', 'null_value');
CALL sp_flag_unparsed('listings', 'price', 'money', 'null_value');
CALL sp_flag_unparsed('listings', 'cleaning_fee', 'money', 'null_value');
CALL sp_flag_unparsed('listings', 'minimum_nights', 'value', 'null_value');
CALL sp_flag_unparsed('listings', 'maximum_nights', 'value', 'null_value');
CALL sp_flag_unparsed('listings', 'created_at', 'date', 'null_value');
CALL sp_flag_unparsed('listings', 'updated_at', 'datetime', 'null_value');

-- Listing points at a known duplicate neighbourhood (held in manual_neighbourhoods).
INSERT INTO manual_issues (table_name, raw_row_id, entity_id, column_name, issue_code, severity, raw_value, detail, suggested_value)
SELECT 'listings', l.raw_row_id, l.entity_id, 'neighbourhood_id', 'points_to_duplicate_neighbourhood', 'hold',
       l.neighbourhood_id_raw, i.detail, i.suggested_value
FROM stg_listings l
JOIN stg_neighbourhoods n ON n.neighbourhood_id = l.neighbourhood_id
JOIN manual_issues i ON i.table_name = 'neighbourhoods' AND i.raw_row_id = n.raw_row_id AND i.issue_code = 'duplicate_neighbourhood';

CALL sp_flag_parent('listings', 'host_id', 'hosts', 'host_id');
CALL sp_flag_parent('listings', 'neighbourhood_id', 'neighbourhoods', 'neighbourhood_id');

INSERT INTO manual_issues (table_name, raw_row_id, entity_id, column_name, issue_code, severity, raw_value, suggested_value)
SELECT 'listings', raw_row_id, entity_id, 'price',
       CASE WHEN price = 0 THEN 'zero_price' WHEN price < 0 THEN 'negative_price' ELSE 'price_outlier' END,
       'null_value', price_raw,
       CASE WHEN price < 0 THEN CAST(-price AS CHAR) WHEN price > @max_nightly_price THEN CAST(price / 100 AS DECIMAL(10,2)) END
FROM stg_listings WHERE price <= 0 OR price > @max_nightly_price;

INSERT INTO manual_issues (table_name, raw_row_id, entity_id, column_name, issue_code, severity, raw_value)
SELECT 'listings', raw_row_id, entity_id, 'cleaning_fee', 'negative_fee', 'null_value', cleaning_fee_raw
FROM stg_listings WHERE cleaning_fee < 0;

INSERT INTO manual_issues (table_name, raw_row_id, entity_id, column_name, issue_code, severity, raw_value)
SELECT 'listings', raw_row_id, entity_id, 'accommodates',
       IF(accommodates < 1, 'non_positive_value', 'value_too_large'), 'null_value', accommodates_raw
FROM stg_listings WHERE accommodates < 1 OR accommodates > 30;

INSERT INTO manual_issues (table_name, raw_row_id, entity_id, column_name, issue_code, severity, raw_value)
SELECT 'listings', raw_row_id, entity_id, 'bedrooms', 'negative_value', 'null_value', bedrooms_raw
FROM stg_listings WHERE bedrooms < 0 OR bedrooms > 50;

INSERT INTO manual_issues (table_name, raw_row_id, entity_id, column_name, issue_code, severity, raw_value)
SELECT 'listings', raw_row_id, entity_id, 'bathrooms', 'negative_value', 'null_value', bathrooms_raw
FROM stg_listings WHERE bathrooms < 0;

-- min > max: can't tell which one is wrong, so both become NULL.
INSERT INTO manual_issues (table_name, raw_row_id, entity_id, column_name, issue_code, severity, raw_value, detail)
SELECT 'listings', raw_row_id, entity_id, col, 'minimum_above_maximum_nights', 'null_value', val,
       CONCAT('min ', minimum_nights, ' > max ', maximum_nights)
FROM (SELECT raw_row_id, entity_id, 'minimum_nights' AS col, minimum_nights_raw AS val, minimum_nights, maximum_nights
      FROM stg_listings WHERE minimum_nights > maximum_nights
      UNION ALL
      SELECT raw_row_id, entity_id, 'maximum_nights', maximum_nights_raw, minimum_nights, maximum_nights
      FROM stg_listings WHERE minimum_nights > maximum_nights) x;

INSERT INTO manual_issues (table_name, raw_row_id, entity_id, column_name, issue_code, severity, raw_value)
SELECT 'listings', raw_row_id, entity_id, 'minimum_nights', 'non_positive_value', 'null_value', minimum_nights_raw
FROM stg_listings WHERE minimum_nights < 1;

-- Coordinates must be near the neighbourhood centre (listings are within ~1 km).
-- If swapping lat/long fixes it, the swap is suggested.
INSERT INTO manual_issues (table_name, raw_row_id, entity_id, column_name, issue_code, severity, raw_value, suggested_value)
SELECT 'listings', x.raw_row_id, x.entity_id, c.col, x.code, 'null_value', IF(c.col = 'latitude', x.latitude_raw, x.longitude_raw),
       IF(x.code = 'coordinates_swapped', IF(c.col = 'latitude', x.longitude, x.latitude), NULL)
FROM (
  SELECT l.raw_row_id, l.entity_id, l.latitude, l.longitude, l.latitude_raw, l.longitude_raw,
         IF(ABS(l.longitude - n.latitude) < 0.05 AND ABS(l.latitude - n.longitude) < 0.05,
            'coordinates_swapped', 'coordinates_outside_area') AS code
  FROM stg_listings l
  JOIN stg_neighbourhoods n ON n.neighbourhood_id = l.neighbourhood_id
  WHERE l.coords_imputed = 0
    AND (ABS(l.latitude - n.latitude) > 0.05 OR ABS(l.longitude - n.longitude) > 0.05)
) x
CROSS JOIN (SELECT 'latitude' AS col UNION ALL SELECT 'longitude') c;

-- Listing can't be created before its host joined.
INSERT INTO manual_issues (table_name, raw_row_id, entity_id, column_name, issue_code, severity, raw_value, detail)
SELECT 'listings', l.raw_row_id, l.entity_id, 'created_at', 'created_before_host_since', 'null_value', l.created_at_raw,
       CONCAT('host joined on ', h.host_since)
FROM stg_listings l
JOIN (SELECT host_id, MIN(host_since) AS host_since FROM stg_hosts GROUP BY host_id) h ON h.host_id = l.host_id
WHERE l.created_at < h.host_since;

INSERT INTO manual_issues (table_name, raw_row_id, entity_id, column_name, issue_code, severity, raw_value, detail)
SELECT 'listings', l.raw_row_id, l.entity_id, 'currency', 'currency_does_not_match_city', 'hold', l.currency_raw,
       CONCAT(n.city, ' uses ', c.currency)
FROM stg_listings l
JOIN airbnb_clean.neighbourhoods n ON n.neighbourhood_id = l.neighbourhood_id
JOIN airbnb_clean.cities c ON c.city = n.city
WHERE l.currency <> c.currency;

CALL sp_finish_table('listings');

-- Listing facts needed by the booking rules.
DROP TABLE IF EXISTS tmp_listing_info;
CREATE TABLE tmp_listing_info (listing_id INT UNSIGNED PRIMARY KEY)
SELECT listing_id, MAX(accommodates) AS accommodates, MAX(currency) AS currency
FROM stg_listings WHERE listing_id IS NOT NULL GROUP BY listing_id;


-- =====================================================================
-- 3.6 LISTING_AMENITIES
-- =====================================================================
CALL sp_archive_exact_duplicates('listing_amenities');

DROP TABLE IF EXISTS stg_listing_amenities;
CREATE TABLE stg_listing_amenities AS
SELECT s.raw_row_id,
       CONCAT(TRIM(s.listing_id), '-', TRIM(s.amenity_id)) AS entity_id,
       fn_parse_id(s.listing_id)                           AS listing_id,
       -- an id (possibly a duplicate spelling's id) or an amenity *name*: both go through map_amenity
       COALESCE(m.amenity_id, fn_parse_id(s.amenity_id))   AS amenity_id,
       s.listing_id AS listing_id_raw, s.amenity_id AS amenity_id_raw,
       1 AS load_ok
FROM src_listing_amenities s
LEFT JOIN map_amenity m
  ON m.raw_key = IF(fn_parse_id(s.amenity_id) IS NOT NULL,
                    CAST(fn_parse_id(s.amenity_id) AS CHAR),
                    LOWER(REGEXP_REPLACE(s.amenity_id, '[^a-z0-9]', '')));
ALTER TABLE stg_listing_amenities ADD PRIMARY KEY (raw_row_id), ADD INDEX (listing_id, amenity_id);

-- After mapping, the same (listing, amenity) pair can show up twice ('5' and 'Wifi').
-- Keep one, archive the rest.
INSERT INTO archive_listing_amenities (raw_row_id, listing_id, amenity_id, archive_reason, kept_raw_row_id)
SELECT r.raw_row_id, r.listing_id, r.amenity_id, 'duplicate_after_mapping', d.keep_id
FROM (SELECT raw_row_id,
             ROW_NUMBER() OVER w AS rn, FIRST_VALUE(raw_row_id) OVER w AS keep_id
      FROM stg_listing_amenities
      WHERE listing_id IS NOT NULL AND amenity_id IS NOT NULL
      WINDOW w AS (PARTITION BY listing_id, amenity_id ORDER BY raw_row_id)) d
JOIN raw_listing_amenities r ON r.raw_row_id = d.raw_row_id
WHERE d.rn > 1;
DELETE s FROM stg_listing_amenities s JOIN archive_listing_amenities a ON a.raw_row_id = s.raw_row_id;

CALL sp_flag_missing('listing_amenities', 'listing_id');
CALL sp_flag_unparsed('listing_amenities', 'listing_id', 'value', 'hold');
CALL sp_flag_missing('listing_amenities', 'amenity_id');
CALL sp_flag_unparsed('listing_amenities', 'amenity_id', 'value', 'hold');
CALL sp_flag_parent('listing_amenities', 'listing_id', 'listings', 'listing_id');
CALL sp_flag_parent('listing_amenities', 'amenity_id', 'amenities', 'amenity_id');

CALL sp_finish_table('listing_amenities');


-- =====================================================================
-- 3.7 BOOKINGS
-- =====================================================================
CALL sp_archive_exact_duplicates('bookings');

DROP TABLE IF EXISTS stg_bookings;
CREATE TABLE stg_bookings AS
SELECT s.raw_row_id,
       TRIM(s.booking_id)                                  AS entity_id,
       fn_parse_id(s.booking_id)                           AS booking_id,
       fn_parse_id(s.listing_id)                           AS listing_id,
       COALESCE(gm.new_id, fn_parse_id(s.guest_id))        AS guest_id,       -- confirmed guest merges applied
       fn_parse_datetime(s.booking_date, 'strict')         AS booking_date,
       DATE(fn_parse_datetime(s.check_in, 'strict'))       AS check_in,
       DATE(fn_parse_datetime(s.check_out, 'strict'))      AS check_out,
       CAST(fn_parse_number(s.num_guests) AS SIGNED)       AS num_guests,
       fn_parse_money(s.nightly_rate)                      AS nightly_rate,
       fn_parse_money(s.cleaning_fee)                      AS cleaning_fee,
       fn_parse_money(s.total_price)                       AS total_price,
       fn_map('currency', s.currency)                      AS currency,
       fn_map('booking_status', s.status)                  AS status,
       fn_map('channel', s.channel)                        AS channel,
       s.booking_id AS booking_id_raw, s.listing_id AS listing_id_raw, s.guest_id AS guest_id_raw,
       s.booking_date AS booking_date_raw, s.check_in AS check_in_raw, s.check_out AS check_out_raw,
       s.num_guests AS num_guests_raw, s.nightly_rate AS nightly_rate_raw, s.cleaning_fee AS cleaning_fee_raw,
       s.total_price AS total_price_raw, s.currency AS currency_raw, s.status AS status_raw, s.channel AS channel_raw,
       1 AS load_ok
FROM src_bookings s
LEFT JOIN map_guest_merge gm ON gm.old_id = fn_parse_id(s.guest_id);
ALTER TABLE stg_bookings ADD PRIMARY KEY (raw_row_id), ADD INDEX (booking_id), ADD INDEX (listing_id), ADD INDEX (guest_id);

-- Auto-fix: missing currency -> the listing's currency
UPDATE stg_bookings b
JOIN tmp_listing_info l ON l.listing_id = b.listing_id
SET b.currency = l.currency
WHERE b.currency IS NULL AND fn_clean_text(b.currency_raw) IS NULL;

CALL sp_flag_missing('bookings', 'booking_id');
CALL sp_flag_unparsed('bookings', 'booking_id', 'value', 'hold');
CALL sp_flag_conflicting_duplicates('bookings', 'booking_id');
CALL sp_flag_missing('bookings', 'listing_id');
CALL sp_flag_unparsed('bookings', 'listing_id', 'value', 'hold');
CALL sp_flag_missing('bookings', 'guest_id');
CALL sp_flag_unparsed('bookings', 'guest_id', 'value', 'hold');
CALL sp_flag_parent('bookings', 'listing_id', 'listings', 'listing_id');
CALL sp_flag_parent('bookings', 'guest_id', 'guests', 'guest_id');
CALL sp_flag_unparsed('bookings', 'booking_date', 'datetime', 'null_value');
CALL sp_flag_missing('bookings', 'check_in');
CALL sp_flag_unparsed('bookings', 'check_in', 'date', 'hold');
CALL sp_flag_missing('bookings', 'check_out');
CALL sp_flag_unparsed('bookings', 'check_out', 'date', 'hold');
CALL sp_flag_unparsed('bookings', 'num_guests', 'value', 'null_value');
CALL sp_flag_missing('bookings', 'nightly_rate');
CALL sp_flag_unparsed('bookings', 'nightly_rate', 'money', 'hold');
CALL sp_flag_missing('bookings', 'cleaning_fee');
CALL sp_flag_unparsed('bookings', 'cleaning_fee', 'money', 'hold');
CALL sp_flag_missing('bookings', 'total_price');
CALL sp_flag_unparsed('bookings', 'total_price', 'money', 'hold');
CALL sp_flag_missing('bookings', 'currency');
CALL sp_flag_unparsed('bookings', 'currency', 'value', 'hold');
CALL sp_flag_unparsed('bookings', 'status', 'value', 'null_value');
CALL sp_flag_missing('bookings', 'channel');
CALL sp_flag_unparsed('bookings', 'channel', 'value', 'hold');

-- Dates
INSERT INTO manual_issues (table_name, raw_row_id, entity_id, column_name, issue_code, severity, raw_value, suggested_value)
SELECT 'bookings', raw_row_id, entity_id, 'check_out',
       IF(check_out < check_in, 'check_out_before_check_in', 'zero_night_stay'), 'hold', check_out_raw,
       IF(check_out < check_in, CONCAT('swap: check_in=', check_out, ', check_out=', check_in), NULL)
FROM stg_bookings WHERE check_out <= check_in;

INSERT INTO manual_issues (table_name, raw_row_id, entity_id, column_name, issue_code, severity, raw_value)
SELECT 'bookings', raw_row_id, entity_id, 'booking_date', 'booking_after_check_in', 'null_value', booking_date_raw
FROM stg_bookings WHERE DATE(booking_date) > check_in AND check_out > check_in;

-- Two non-cancelled bookings on one listing that overlap: the later one is held.
-- Running MAX(check_out) over the earlier bookings on the listing.
INSERT INTO manual_issues (table_name, raw_row_id, entity_id, column_name, issue_code, severity, raw_value, detail)
SELECT 'bookings', raw_row_id, entity_id, 'check_in', 'overlapping_booking', 'hold', check_in_raw,
       CONCAT('listing ', listing_id, ' is already booked until ', prev_end)
FROM (
  SELECT b.*,
         MAX(check_out) OVER (PARTITION BY listing_id ORDER BY check_in, booking_id
                              ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING) AS prev_end
  FROM stg_bookings b
  WHERE listing_id IS NOT NULL AND check_in IS NOT NULL AND check_out > check_in
    AND COALESCE(status, '') <> 'cancelled'
    AND booking_id NOT IN (SELECT booking_id FROM stg_bookings WHERE booking_id IS NOT NULL
                           GROUP BY booking_id HAVING COUNT(*) > 1)
) x
WHERE check_in < prev_end;

-- Guests
INSERT INTO manual_issues (table_name, raw_row_id, entity_id, column_name, issue_code, severity, raw_value, detail)
SELECT 'bookings', b.raw_row_id, b.entity_id, 'num_guests',
       IF(b.num_guests < 1, 'non_positive_value', 'guests_exceed_capacity'), 'null_value', b.num_guests_raw,
       IF(b.num_guests < 1, NULL, CONCAT('listing sleeps ', COALESCE(l.accommodates, '?')))
FROM stg_bookings b
LEFT JOIN tmp_listing_info l ON l.listing_id = b.listing_id
WHERE b.num_guests < 1 OR b.num_guests > COALESCE(l.accommodates, 30);

-- Money
INSERT INTO manual_issues (table_name, raw_row_id, entity_id, column_name, issue_code, severity, raw_value, suggested_value)
SELECT 'bookings', raw_row_id, entity_id, 'nightly_rate', 'price_outlier', 'hold', nightly_rate_raw,
       CAST(nightly_rate / 100 AS DECIMAL(10,2))
FROM stg_bookings WHERE nightly_rate > @max_nightly_price;

INSERT INTO manual_issues (table_name, raw_row_id, entity_id, column_name, issue_code, severity, raw_value)
SELECT 'bookings', raw_row_id, entity_id, 'nightly_rate', 'non_positive_value', 'hold', nightly_rate_raw
FROM stg_bookings WHERE nightly_rate <= 0;

INSERT INTO manual_issues (table_name, raw_row_id, entity_id, column_name, issue_code, severity, raw_value, suggested_value)
SELECT 'bookings', raw_row_id, entity_id, 'total_price', 'negative_total', 'hold', total_price_raw, CAST(-total_price AS CHAR)
FROM stg_bookings WHERE total_price < 0;

-- README rule: total = nights x nightly_rate + cleaning_fee (same as the CHECK in airbnb_clean).
INSERT INTO manual_issues (table_name, raw_row_id, entity_id, column_name, issue_code, severity, raw_value, suggested_value)
SELECT 'bookings', raw_row_id, entity_id, 'total_price', 'total_does_not_match', 'hold', total_price_raw,
       CAST(DATEDIFF(check_out, check_in) * nightly_rate + cleaning_fee AS CHAR)
FROM stg_bookings
WHERE check_out > check_in AND total_price >= 0
  AND total_price <> DATEDIFF(check_out, check_in) * nightly_rate + cleaning_fee;

INSERT INTO manual_issues (table_name, raw_row_id, entity_id, column_name, issue_code, severity, raw_value, detail)
SELECT 'bookings', b.raw_row_id, b.entity_id, 'currency', 'currency_does_not_match_listing', 'hold', b.currency_raw,
       CONCAT('listing is priced in ', l.currency)
FROM stg_bookings b JOIN tmp_listing_info l ON l.listing_id = b.listing_id
WHERE b.currency <> l.currency;

-- Missing status: loaded as NULL, with a suggested value based on payments/reviews.
DROP TABLE IF EXISTS tmp_booking_evidence;
CREATE TABLE tmp_booking_evidence (booking_id INT UNSIGNED PRIMARY KEY)
SELECT booking_id, MAX(has_review) AS has_review, MAX(has_refund) AS has_refund, MAX(has_paid) AS has_paid
FROM (SELECT fn_parse_id(booking_id) AS booking_id, 0 AS has_review,
             fn_map('payment_status', payment_status) = 'refunded' AS has_refund,
             fn_map('payment_status', payment_status) = 'completed' AS has_paid
      FROM raw_payments
      UNION ALL
      SELECT fn_parse_id(booking_id), 1, 0, 0 FROM raw_reviews) e
WHERE booking_id IS NOT NULL
GROUP BY booking_id;

INSERT INTO manual_issues (table_name, raw_row_id, entity_id, column_name, issue_code, severity, raw_value, suggested_value)
SELECT 'bookings', b.raw_row_id, b.entity_id, 'status', 'status_missing', 'null_value', b.status_raw,
       CASE WHEN e.has_review = 1 THEN 'completed (has a review)'
            WHEN e.has_refund = 1 THEN 'cancelled (was refunded)'
            WHEN b.check_out > @snapshot_date THEN 'confirmed (stay is in the future)'
            WHEN e.has_paid = 1 THEN 'completed (paid, stay is over)'
            ELSE 'cancelled (never paid)' END
FROM stg_bookings b
LEFT JOIN tmp_booking_evidence e ON e.booking_id = b.booking_id
WHERE b.status IS NULL AND fn_clean_text(b.status_raw) IS NULL;

CALL sp_finish_table('bookings');

-- Booking facts needed by the payment and review rules. *_trusted = the booking's own
-- value passed its checks. Comparing a payment to a wrong total would only give false alarms.
DROP TABLE IF EXISTS tmp_booking_info;
CREATE TABLE tmp_booking_info (booking_id INT UNSIGNED PRIMARY KEY)
SELECT b.booking_id, MAX(b.listing_id) AS listing_id, MAX(b.guest_id) AS guest_id, MAX(b.booking_date) AS booking_date,
       MAX(b.check_out) AS check_out, MAX(b.total_price) AS total_price, MAX(b.currency) AS currency,
       COUNT(*) = 1 AND MAX(COALESCE(i.bad_listing, 0)) = 0 AS listing_trusted,
       COUNT(*) = 1 AND MAX(COALESCE(i.bad_guest, 0)) = 0   AS guest_trusted,
       COUNT(*) = 1 AND MAX(COALESCE(i.bad_money, 0)) = 0   AS total_trusted
FROM stg_bookings b
LEFT JOIN (SELECT raw_row_id,
                  MAX(column_name = 'listing_id' AND severity = 'hold') AS bad_listing,
                  MAX(column_name = 'guest_id' AND severity = 'hold')   AS bad_guest,
                  MAX(column_name IN ('total_price', 'nightly_rate', 'cleaning_fee', 'check_in', 'check_out')) AS bad_money
           FROM manual_issues WHERE table_name = 'bookings' GROUP BY raw_row_id) i ON i.raw_row_id = b.raw_row_id
WHERE b.booking_id IS NOT NULL
GROUP BY b.booking_id;


-- =====================================================================
-- 3.8 PAYMENTS
-- =====================================================================
CALL sp_archive_exact_duplicates('payments');

DROP TABLE IF EXISTS stg_payments;
CREATE TABLE stg_payments AS
SELECT s.raw_row_id,
       TRIM(s.payment_id)                                  AS entity_id,
       fn_parse_id(s.payment_id)                           AS payment_id,
       fn_parse_id(s.booking_id)                           AS booking_id,
       fn_parse_datetime(s.payment_date, 'strict')         AS payment_date,
       fn_parse_money(s.amount)                            AS amount,
       fn_map('currency', s.currency)                      AS currency,
       fn_map('payment_method', s.payment_method)          AS payment_method,
       fn_map('payment_status', s.payment_status)          AS payment_status,
       -- 'txn-00ab12cd34', ' TXN-...', 'TXN00AB12CD34' -> 'TXN-00AB12CD34'
       REGEXP_REPLACE(UPPER(TRIM(s.transaction_ref)), '^TXN-?', 'TXN-') AS transaction_ref,
       s.payment_id AS payment_id_raw, s.booking_id AS booking_id_raw, s.payment_date AS payment_date_raw,
       s.amount AS amount_raw, s.currency AS currency_raw, s.payment_method AS payment_method_raw,
       s.payment_status AS payment_status_raw, s.transaction_ref AS transaction_ref_raw,
       1 AS load_ok
FROM src_payments s;
ALTER TABLE stg_payments ADD PRIMARY KEY (raw_row_id), ADD INDEX (payment_id), ADD INDEX (booking_id);

-- Auto-fixes: refunds are negative; missing currency -> the booking's currency
UPDATE stg_payments SET amount = -amount WHERE payment_status = 'refunded' AND amount > 0;
UPDATE stg_payments p
JOIN tmp_booking_info b ON b.booking_id = p.booking_id
SET p.currency = b.currency
WHERE p.currency IS NULL AND fn_clean_text(p.currency_raw) IS NULL;

CALL sp_flag_missing('payments', 'payment_id');
CALL sp_flag_unparsed('payments', 'payment_id', 'value', 'hold');
CALL sp_flag_conflicting_duplicates('payments', 'payment_id');
CALL sp_flag_missing('payments', 'booking_id');
CALL sp_flag_unparsed('payments', 'booking_id', 'value', 'hold');
CALL sp_flag_parent('payments', 'booking_id', 'bookings', 'booking_id');
CALL sp_flag_missing('payments', 'payment_date');
CALL sp_flag_unparsed('payments', 'payment_date', 'datetime', 'hold');
CALL sp_flag_missing('payments', 'amount');
CALL sp_flag_unparsed('payments', 'amount', 'money', 'hold');
CALL sp_flag_missing('payments', 'currency');
CALL sp_flag_unparsed('payments', 'currency', 'value', 'hold');
CALL sp_flag_unparsed('payments', 'payment_method', 'value', 'null_value');
CALL sp_flag_missing('payments', 'payment_status');
CALL sp_flag_unparsed('payments', 'payment_status', 'value', 'hold');
CALL sp_flag_missing('payments', 'transaction_ref');

INSERT INTO manual_issues (table_name, raw_row_id, entity_id, column_name, issue_code, severity, raw_value)
SELECT 'payments', raw_row_id, entity_id, 'transaction_ref', 'invalid_transaction_ref', 'hold', transaction_ref_raw
FROM stg_payments
WHERE transaction_ref IS NOT NULL AND NOT REGEXP_LIKE(transaction_ref, '^TXN-[0-9A-F]{10}$', 'c');

-- Same transaction ref on two payments: possible double charge. First one is kept.
INSERT INTO manual_issues (table_name, raw_row_id, entity_id, column_name, issue_code, severity, raw_value, detail)
SELECT 'payments', raw_row_id, entity_id, 'transaction_ref', 'reused_transaction_ref', 'hold', transaction_ref_raw,
       CONCAT('already used by payment ', first_payment)
FROM (SELECT raw_row_id, entity_id, transaction_ref_raw, payment_id,
             ROW_NUMBER() OVER w AS rn, FIRST_VALUE(payment_id) OVER w AS first_payment
      FROM stg_payments WHERE transaction_ref IS NOT NULL
      WINDOW w AS (PARTITION BY transaction_ref ORDER BY payment_id, raw_row_id)) x
WHERE rn > 1 AND first_payment <> payment_id;

INSERT INTO manual_issues (table_name, raw_row_id, entity_id, column_name, issue_code, severity, raw_value)
SELECT 'payments', raw_row_id, entity_id, 'amount',
       IF(amount = 0, 'zero_amount', 'negative_amount_not_refund'), 'hold', amount_raw
FROM stg_payments WHERE amount = 0 OR (amount < 0 AND payment_status <> 'refunded');

-- Payment more than a day before the booking was made (a failed attempt minutes before is normal).
INSERT INTO manual_issues (table_name, raw_row_id, entity_id, column_name, issue_code, severity, raw_value, detail)
SELECT 'payments', p.raw_row_id, p.entity_id, 'payment_date', 'paid_before_booked', 'hold', p.payment_date_raw,
       CONCAT('booking made on ', b.booking_date)
FROM stg_payments p JOIN tmp_booking_info b ON b.booking_id = p.booking_id
WHERE p.payment_date < b.booking_date - INTERVAL 1 DAY;

INSERT INTO manual_issues (table_name, raw_row_id, entity_id, column_name, issue_code, severity, raw_value, detail)
SELECT 'payments', p.raw_row_id, p.entity_id, 'currency', 'currency_does_not_match_booking', 'hold', p.currency_raw,
       CONCAT('booking is in ', b.currency)
FROM stg_payments p JOIN tmp_booking_info b ON b.booking_id = p.booking_id
WHERE p.currency <> b.currency;

-- Completed, pending or failed charge must be the total, the 30% deposit or the 70% balance.
-- Only checked when the booking total itself is trusted.
INSERT INTO manual_issues (table_name, raw_row_id, entity_id, column_name, issue_code, severity, raw_value, suggested_value)
SELECT 'payments', p.raw_row_id, p.entity_id, 'amount', 'amount_does_not_reconcile', 'hold', p.amount_raw,
       CONCAT(b.total_price, ' (booking total)')
FROM stg_payments p JOIN tmp_booking_info b ON b.booking_id = p.booking_id
WHERE p.payment_status IN ('completed', 'pending', 'failed')
  AND b.total_trusted = 1
  AND p.amount > 0 AND b.total_price > 0
  AND p.amount <> b.total_price
  AND ABS(p.amount - b.total_price * 0.3) > 0.01      -- 1 cent slack: 30% of 628.75 can be stored as .62 or .63
  AND ABS(p.amount - b.total_price * 0.7) > 0.01;

CALL sp_finish_table('payments');


-- =====================================================================
-- 3.9 REVIEWS
-- =====================================================================
CALL sp_archive_exact_duplicates('reviews');

DROP TABLE IF EXISTS stg_reviews;
CREATE TABLE stg_reviews AS
SELECT s.raw_row_id,
       TRIM(s.review_id)                                   AS entity_id,
       fn_parse_id(s.review_id)                            AS review_id,
       fn_parse_id(s.booking_id)                           AS booking_id,
       fn_parse_id(s.listing_id)                           AS listing_id,
       COALESCE(gm.new_id, fn_parse_id(s.guest_id))        AS guest_id,
       DATE(fn_parse_datetime(s.review_date, 'strict'))    AS review_date,
       CAST(fn_parse_number(s.rating) AS SIGNED)           AS rating,
       CAST(fn_parse_number(s.cleanliness) AS SIGNED)      AS cleanliness,
       CAST(fn_parse_number(s.communication) AS SIGNED)    AS communication,
       CAST(fn_parse_number(s.`value`) AS SIGNED)          AS `value`,
       fn_fix_text(s.comments)                             AS comments,
       s.review_id AS review_id_raw, s.booking_id AS booking_id_raw, s.listing_id AS listing_id_raw,
       s.guest_id AS guest_id_raw, s.review_date AS review_date_raw, s.rating AS rating_raw,
       s.cleanliness AS cleanliness_raw, s.communication AS communication_raw, s.`value` AS value_raw,
       s.comments AS comments_raw,
       1 AS load_ok
FROM src_reviews s
LEFT JOIN map_guest_merge gm ON gm.old_id = fn_parse_id(s.guest_id);
ALTER TABLE stg_reviews ADD PRIMARY KEY (raw_row_id), ADD INDEX (review_id), ADD INDEX (booking_id);

CALL sp_flag_missing('reviews', 'review_id');
CALL sp_flag_unparsed('reviews', 'review_id', 'value', 'hold');
CALL sp_flag_conflicting_duplicates('reviews', 'review_id');
CALL sp_flag_missing('reviews', 'booking_id');
CALL sp_flag_unparsed('reviews', 'booking_id', 'value', 'hold');
CALL sp_flag_parent('reviews', 'booking_id', 'bookings', 'booking_id');
CALL sp_flag_unparsed('reviews', 'review_date', 'date', 'null_value');
CALL sp_flag_unparsed('reviews', 'rating', 'value', 'null_value');
CALL sp_flag_unparsed('reviews', 'cleanliness', 'value', 'null_value');
CALL sp_flag_unparsed('reviews', 'communication', 'value', 'null_value');
CALL sp_flag_unparsed('reviews', 'value', 'value', 'null_value');

-- Review must be about the booking's listing, by the booking's guest.
INSERT INTO manual_issues (table_name, raw_row_id, entity_id, column_name, issue_code, severity, raw_value, suggested_value)
SELECT 'reviews', r.raw_row_id, r.entity_id, 'listing_id', 'listing_does_not_match_booking', 'hold', r.listing_id_raw,
       CAST(b.listing_id AS CHAR)
FROM stg_reviews r JOIN tmp_booking_info b ON b.booking_id = r.booking_id
WHERE b.listing_trusted = 1 AND (r.listing_id IS NULL OR r.listing_id <> b.listing_id);

INSERT INTO manual_issues (table_name, raw_row_id, entity_id, column_name, issue_code, severity, raw_value, suggested_value)
SELECT 'reviews', r.raw_row_id, r.entity_id, 'guest_id', 'guest_does_not_match_booking', 'hold', r.guest_id_raw,
       CAST(b.guest_id AS CHAR)
FROM stg_reviews r JOIN tmp_booking_info b ON b.booking_id = r.booking_id
WHERE b.guest_trusted = 1 AND (r.guest_id IS NULL OR r.guest_id <> b.guest_id);

-- One review per booking, the first (lowest id) is kept.
INSERT INTO manual_issues (table_name, raw_row_id, entity_id, column_name, issue_code, severity, raw_value, detail)
SELECT 'reviews', raw_row_id, entity_id, 'booking_id', 'second_review_for_booking', 'hold', booking_id_raw,
       CONCAT('booking already reviewed in review ', first_review)
FROM (SELECT raw_row_id, entity_id, booking_id_raw, review_id,
             ROW_NUMBER() OVER w AS rn, FIRST_VALUE(review_id) OVER w AS first_review
      FROM stg_reviews WHERE booking_id IS NOT NULL
      WINDOW w AS (PARTITION BY booking_id ORDER BY review_id, raw_row_id)) x
WHERE rn > 1 AND first_review <> review_id;

INSERT INTO manual_issues (table_name, raw_row_id, entity_id, column_name, issue_code, severity, raw_value, detail)
SELECT 'reviews', r.raw_row_id, r.entity_id, 'review_date', 'review_before_check_out', 'null_value', r.review_date_raw,
       CONCAT('check-out was ', b.check_out)
FROM stg_reviews r JOIN tmp_booking_info b ON b.booking_id = r.booking_id
WHERE r.review_date < b.check_out;

INSERT INTO manual_issues (table_name, raw_row_id, entity_id, column_name, issue_code, severity, raw_value)
SELECT 'reviews', raw_row_id, entity_id, 'review_date', 'date_in_future', 'null_value', review_date_raw
FROM stg_reviews WHERE review_date > @snapshot_date;

-- Scores must be 1-5. A 6-10 is likely out of 10, so half of it is suggested.
INSERT INTO manual_issues (table_name, raw_row_id, entity_id, column_name, issue_code, severity, raw_value, suggested_value)
SELECT 'reviews', raw_row_id, entity_id, col, 'score_out_of_range', 'null_value', val,
       IF(score BETWEEN 6 AND 10, CONCAT(ROUND(score / 2), ' if it was out of 10'), NULL)
FROM (SELECT raw_row_id, entity_id, 'rating' AS col, rating_raw AS val, rating AS score FROM stg_reviews
      UNION ALL SELECT raw_row_id, entity_id, 'cleanliness', cleanliness_raw, cleanliness FROM stg_reviews
      UNION ALL SELECT raw_row_id, entity_id, 'communication', communication_raw, communication FROM stg_reviews
      UNION ALL SELECT raw_row_id, entity_id, 'value', value_raw, `value` FROM stg_reviews) x
WHERE score NOT BETWEEN 1 AND 5;

-- Test / junk text isn't a real review, so the whole row is held.
INSERT INTO manual_issues (table_name, raw_row_id, entity_id, column_name, issue_code, severity, raw_value)
SELECT 'reviews', raw_row_id, entity_id, 'comments', 'junk_review', 'hold', comments_raw
FROM stg_reviews
WHERE REGEXP_LIKE(comments, '^(test|asdf|qwer|xxx|lorem)|please ignore')
   OR REGEXP_LIKE(comments, '^[^a-z0-9]*$');

CALL sp_finish_table('reviews');


-- #####################################################################
-- PART 4. Report
-- #####################################################################

-- 4.1 Where every raw row went: raw = archived + clean + held + resolved_by_person  (balanced = 1)
SELECT t.tbl,
       t.raw_rows, t.archived, t.in_clean, t.held_in_manual, t.resolved_by_person,
       (t.raw_rows = t.archived + t.in_clean + t.held_in_manual + t.resolved_by_person) AS balanced
FROM (
  SELECT 'neighbourhoods' AS tbl, (SELECT COUNT(*) FROM raw_neighbourhoods) AS raw_rows, (SELECT COUNT(*) FROM archive_neighbourhoods) AS archived,
         (SELECT COUNT(*) FROM airbnb_clean.neighbourhoods) AS in_clean,
         (SELECT COUNT(*) FROM stg_neighbourhoods WHERE load_ok = 0) AS held_in_manual,
         (SELECT COUNT(*) FROM manual_neighbourhoods WHERE review_status IN ('rejected', 'merged')) AS resolved_by_person
  UNION ALL SELECT 'hosts', (SELECT COUNT(*) FROM raw_hosts), (SELECT COUNT(*) FROM archive_hosts), (SELECT COUNT(*) FROM airbnb_clean.hosts),
         (SELECT COUNT(*) FROM stg_hosts WHERE load_ok = 0), (SELECT COUNT(*) FROM manual_hosts WHERE review_status IN ('rejected', 'merged'))
  UNION ALL SELECT 'guests', (SELECT COUNT(*) FROM raw_guests), (SELECT COUNT(*) FROM archive_guests), (SELECT COUNT(*) FROM airbnb_clean.guests),
         (SELECT COUNT(*) FROM stg_guests WHERE load_ok = 0), (SELECT COUNT(*) FROM manual_guests WHERE review_status IN ('rejected', 'merged'))
  UNION ALL SELECT 'amenities', (SELECT COUNT(*) FROM raw_amenities), (SELECT COUNT(*) FROM archive_amenities), (SELECT COUNT(*) FROM airbnb_clean.amenities),
         (SELECT COUNT(*) FROM stg_amenities WHERE load_ok = 0), (SELECT COUNT(*) FROM manual_amenities WHERE review_status IN ('rejected', 'merged'))
  UNION ALL SELECT 'listings', (SELECT COUNT(*) FROM raw_listings), (SELECT COUNT(*) FROM archive_listings), (SELECT COUNT(*) FROM airbnb_clean.listings),
         (SELECT COUNT(*) FROM stg_listings WHERE load_ok = 0), (SELECT COUNT(*) FROM manual_listings WHERE review_status IN ('rejected', 'merged'))
  UNION ALL SELECT 'listing_amenities', (SELECT COUNT(*) FROM raw_listing_amenities), (SELECT COUNT(*) FROM archive_listing_amenities),
         (SELECT COUNT(*) FROM airbnb_clean.listing_amenities),
         (SELECT COUNT(*) FROM stg_listing_amenities WHERE load_ok = 0), (SELECT COUNT(*) FROM manual_listing_amenities WHERE review_status IN ('rejected', 'merged'))
  UNION ALL SELECT 'bookings', (SELECT COUNT(*) FROM raw_bookings), (SELECT COUNT(*) FROM archive_bookings), (SELECT COUNT(*) FROM airbnb_clean.bookings),
         (SELECT COUNT(*) FROM stg_bookings WHERE load_ok = 0), (SELECT COUNT(*) FROM manual_bookings WHERE review_status IN ('rejected', 'merged'))
  UNION ALL SELECT 'payments', (SELECT COUNT(*) FROM raw_payments), (SELECT COUNT(*) FROM archive_payments), (SELECT COUNT(*) FROM airbnb_clean.payments),
         (SELECT COUNT(*) FROM stg_payments WHERE load_ok = 0), (SELECT COUNT(*) FROM manual_payments WHERE review_status IN ('rejected', 'merged'))
  UNION ALL SELECT 'reviews', (SELECT COUNT(*) FROM raw_reviews), (SELECT COUNT(*) FROM archive_reviews), (SELECT COUNT(*) FROM airbnb_clean.reviews),
         (SELECT COUNT(*) FROM stg_reviews WHERE load_ok = 0), (SELECT COUNT(*) FROM manual_reviews WHERE review_status IN ('rejected', 'merged'))
) t;

-- 4.2 Archive contents and reasons
SELECT 'hosts' AS tbl, archive_reason, COUNT(*) AS n FROM archive_hosts GROUP BY archive_reason
UNION ALL SELECT 'neighbourhoods', archive_reason, COUNT(*) FROM archive_neighbourhoods GROUP BY archive_reason
UNION ALL SELECT 'guests', archive_reason, COUNT(*) FROM archive_guests GROUP BY archive_reason
UNION ALL SELECT 'amenities', archive_reason, COUNT(*) FROM archive_amenities GROUP BY archive_reason
UNION ALL SELECT 'listings', archive_reason, COUNT(*) FROM archive_listings GROUP BY archive_reason
UNION ALL SELECT 'listing_amenities', archive_reason, COUNT(*) FROM archive_listing_amenities GROUP BY archive_reason
UNION ALL SELECT 'bookings', archive_reason, COUNT(*) FROM archive_bookings GROUP BY archive_reason
UNION ALL SELECT 'payments', archive_reason, COUNT(*) FROM archive_payments GROUP BY archive_reason
UNION ALL SELECT 'reviews', archive_reason, COUNT(*) FROM archive_reviews GROUP BY archive_reason
ORDER BY tbl, archive_reason;

-- 4.3 Manual work queue by table and issue ('waiting' rows need no action)
SELECT table_name, severity, issue_code, COUNT(*) AS issues, COUNT(DISTINCT raw_row_id) AS row_count
FROM manual_issues
GROUP BY table_name, severity, issue_code
ORDER BY table_name, FIELD(severity, 'hold', 'null_value', 'keep_value', 'waiting'), issues DESC;



