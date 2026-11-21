-- =====================================================================
-- 04_manual_review.sql  -  resolving the manual_* tables   (MySQL 8.0)
-- =====================================================================
-- Workflow:
--   1. 03 puts rows it can't fix safely into airbnb_raw.manual_<table>.
--   2. This script resolves them by updating manual_<table>:
--        - raw values corrected                   ->  review_status = 'fixed'
--        - row is fine as it is                   ->  review_status = 'approved'
--        - row dropped                            ->  review_status = 'rejected'
--        - duplicate guest/neighbourhood          ->  review_status = 'merged' (+ merge_into_id)
--   3. Rerun 03. It re-checks 'fixed'/'approved' rows and loads the ones that now pass.
--      Anything that still fails goes back to 'open' with the edits kept.
--
-- raw_* and airbnb_clean are never touched here. Only 03 writes to clean.
--
-- Notes:
--   * Each section has REVIEW queries (SELECT) and RESOLVE statements (UPDATE).
--     Bulk UPDATEs only change a row when other data backs the fix up
--     (e.g. the booking total only adds up with one reading of the date).
--   * Whole file:
--       "C:\Program Files\MySQL\MySQL Server 8.0\bin\mysql.exe" --default-character-set=utf8mb4 -u root -p < 04_manual_review.sql
--     then rerun 03. Also works section by section in Workbench (no DELIMITER).
--   * Judgement calls (overlaps, orphans, conflicting duplicates) are commented-out templates.
--   * Reset: DELETE FROM manual_<table>; then rerun 03 (it rebuilds the rows from raw).
-- =====================================================================

USE airbnb_raw;
SET SQL_SAFE_UPDATES = 0;          -- Workbench blocks UPDATE ... JOIN without a key otherwise
SET @snapshot_date = DATE('2026-11-19');


-- #####################################################################
-- 0. STATUS   (run again at the end and after rerunning 03)
-- #####################################################################

-- Rows per table and status. needs_action = 0 means only waiting on a parent row.
SELECT 'neighbourhoods' AS tbl, review_status, needs_action, in_clean, COUNT(*) AS n_rows FROM manual_neighbourhoods GROUP BY 2,3,4
UNION ALL SELECT 'hosts', review_status, needs_action, in_clean, COUNT(*) FROM manual_hosts GROUP BY 2,3,4
UNION ALL SELECT 'guests', review_status, needs_action, in_clean, COUNT(*) FROM manual_guests GROUP BY 2,3,4
UNION ALL SELECT 'listings', review_status, needs_action, in_clean, COUNT(*) FROM manual_listings GROUP BY 2,3,4
UNION ALL SELECT 'listing_amenities', review_status, needs_action, in_clean, COUNT(*) FROM manual_listing_amenities GROUP BY 2,3,4
UNION ALL SELECT 'bookings', review_status, needs_action, in_clean, COUNT(*) FROM manual_bookings GROUP BY 2,3,4
UNION ALL SELECT 'payments', review_status, needs_action, in_clean, COUNT(*) FROM manual_payments GROUP BY 2,3,4
UNION ALL SELECT 'reviews', review_status, needs_action, in_clean, COUNT(*) FROM manual_reviews GROUP BY 2,3,4
ORDER BY tbl, review_status, needs_action, in_clean;

-- Open work: which problems hold rows back and which only NULLed a value.
SELECT table_name, severity, issue_code, COUNT(DISTINCT raw_row_id) AS n_rows
FROM manual_issues
WHERE severity <> 'waiting'
GROUP BY table_name, severity, issue_code
ORDER BY table_name, severity, n_rows DESC;

-- Looking at one row and all its issues:
-- SELECT * FROM manual_bookings WHERE raw_row_id = 123;
-- SELECT column_name, issue_code, raw_value, detail, suggested_value FROM manual_issues
-- WHERE table_name = 'bookings' AND raw_row_id = 123;


-- #####################################################################
-- 1. NEIGHBOURHOODS: same neighbourhood entered twice
-- #####################################################################

-- REVIEW: each duplicate next to the neighbourhood it matches
SELECT m.raw_row_id, m.neighbourhood_id, m.neighbourhood_name, m.city, m.merge_into_id,
       n.neighbourhood_name AS merge_into_name
FROM manual_neighbourhoods m
LEFT JOIN airbnb_clean.neighbourhoods n ON n.neighbourhood_id = m.merge_into_id
WHERE m.review_status = 'open' AND m.issue_summary LIKE '%duplicate_neighbourhood%';

-- RESOLVE: merge. Next run re-points listings to merge_into_id, which releases
-- those listings and their bookings.
UPDATE manual_neighbourhoods
SET review_status = 'merged', reviewer_note = 'same name and centre as merge_into_id'
WHERE review_status = 'open' AND issue_summary LIKE '%duplicate_neighbourhood%' AND merge_into_id IS NOT NULL;


-- #####################################################################
-- 2. HOSTS (already in clean, only single values were set to NULL)
-- #####################################################################

-- REVIEW
SELECT i.issue_code, i.raw_value, i.detail, i.suggested_value, m.host_id, m.first_name, m.last_name
FROM manual_issues i JOIN manual_hosts m ON m.raw_row_id = i.raw_row_id
WHERE i.table_name = 'hosts' AND m.review_status = 'open'
ORDER BY i.issue_code
LIMIT 200;

-- RESOLVE: full name typed into first_name with an empty last_name -> split it.
UPDATE manual_hosts
SET last_name  = SUBSTRING(REGEXP_REPLACE(TRIM(first_name), ' +', ' '), LOCATE(' ', REGEXP_REPLACE(TRIM(first_name), ' +', ' ')) + 1),
    first_name = SUBSTRING_INDEX(REGEXP_REPLACE(TRIM(first_name), ' +', ' '), ' ', 1),
    review_status = 'fixed', reviewer_note = 'split full name'
WHERE review_status = 'open' AND issue_summary = 'full_name_in_first_name';

-- Shared e-mail between two hosts: kept in clean but flagged. Once checked:
-- UPDATE manual_hosts SET review_status = 'approved', reviewer_note = 'couple sharing an inbox'
-- WHERE raw_row_id = 123;

-- Invalid e-mail / phone, impossible host_since, response_rate > 100%: row is in clean
-- with that value NULL. If the right value can be found, set it and mark it fixed:
-- UPDATE manual_hosts SET email = 'anna.smith@gmail.com', review_status = 'fixed' WHERE raw_row_id = 123;
-- The rest can stay 'open', they don't block anything.


-- #####################################################################
-- 3. GUESTS: probable duplicate accounts
-- #####################################################################

-- REVIEW: duplicate next to the guest it would merge into
SELECT m.raw_row_id, m.guest_id, m.first_name, m.last_name, m.email, m.phone, m.date_of_birth,
       i.detail, g.guest_id AS into_id, g.email AS into_email, g.phone AS into_phone, g.date_of_birth AS into_dob
FROM manual_guests m
JOIN manual_issues i ON i.table_name = 'guests' AND i.raw_row_id = m.raw_row_id AND i.issue_code = 'duplicate_guest'
LEFT JOIN airbnb_clean.guests g ON g.guest_id = m.merge_into_id
WHERE m.review_status = 'open'
LIMIT 200;

-- RESOLVE: each match key needs two strong signals (name + birth date, name + phone,
-- or e-mail + phone), so I accept all suggested merges. Next run moves the duplicate's
-- bookings and reviews to merge_into_id.
UPDATE manual_guests
SET review_status = 'merged', reviewer_note = 'accepted suggested merge'
WHERE review_status = 'open' AND issue_summary LIKE '%duplicate_guest%' AND merge_into_id IS NOT NULL;

-- If it turns out to be a different person (twins, common name):
-- UPDATE manual_guests SET review_status = 'approved', merge_into_id = NULL, reviewer_note = 'different person'
-- WHERE raw_row_id = 123;


-- #####################################################################
-- 4. LISTINGS
-- #####################################################################

-- REVIEW
SELECT i.issue_code, i.severity, COUNT(*) AS n FROM manual_issues i
WHERE i.table_name = 'listings' AND i.severity <> 'waiting' GROUP BY 1, 2 ORDER BY n DESC;

-- RESOLVE 4a: lat/long swapped (03 checked the swap puts the listing inside its neighbourhood).
-- Reads from a copy (subquery x) because "SET a = b, b = a" in MySQL gives both columns the same value.
UPDATE manual_listings m
JOIN (SELECT raw_row_id, latitude AS old_lat, longitude AS old_lon FROM manual_listings
      WHERE review_status = 'open' AND issue_summary LIKE '%coordinates_swapped%') x ON x.raw_row_id = m.raw_row_id
SET m.latitude = x.old_lon, m.longitude = x.old_lat, m.review_status = 'fixed', m.reviewer_note = 'swapped lat/long back';

-- RESOLVE 4b: price 100x too big. Only when the listing's bookings agree
-- (nightly rate between price/100 and price/100 x 1.25 for seasonal uplift).
UPDATE manual_listings m
JOIN (SELECT ml.raw_row_id, MAX(i.suggested_value) AS new_price
      FROM manual_listings ml
      JOIN manual_issues i ON i.table_name = 'listings' AND i.raw_row_id = ml.raw_row_id AND i.issue_code = 'price_outlier'
      JOIN airbnb_clean.bookings b ON b.listing_id = airbnb_raw.fn_parse_id(ml.listing_id)
      WHERE ml.review_status = 'open'
        AND b.nightly_rate BETWEEN i.suggested_value AND i.suggested_value * 1.25
      GROUP BY ml.raw_row_id) x ON x.raw_row_id = m.raw_row_id
SET m.price = x.new_price, m.review_status = 'fixed', m.reviewer_note = 'price / 100, matches bookings';

-- RESOLVE 4c: negative price -> drop the minus, again only when bookings agree.
UPDATE manual_listings m
JOIN (SELECT ml.raw_row_id, MAX(i.suggested_value) AS new_price
      FROM manual_listings ml
      JOIN manual_issues i ON i.table_name = 'listings' AND i.raw_row_id = ml.raw_row_id AND i.issue_code = 'negative_price'
      JOIN airbnb_clean.bookings b ON b.listing_id = airbnb_raw.fn_parse_id(ml.listing_id)
      WHERE ml.review_status = 'open'
        AND b.nightly_rate BETWEEN i.suggested_value AND i.suggested_value * 1.25
      GROUP BY ml.raw_row_id) x ON x.raw_row_id = m.raw_row_id
SET m.price = x.new_price, m.review_status = 'fixed', m.reviewer_note = 'removed minus sign, matches bookings';

-- RESOLVE 4d: '$' on a GBP/EUR price. Treated as a typo when the bookings agree.
UPDATE manual_listings m
JOIN (SELECT ml.raw_row_id
      FROM manual_listings ml
      JOIN manual_issues i ON i.table_name = 'listings' AND i.raw_row_id = ml.raw_row_id
                          AND i.issue_code = 'dollar_sign_vs_currency' AND i.column_name = 'price'
      JOIN airbnb_clean.bookings b ON b.listing_id = airbnb_raw.fn_parse_id(ml.listing_id)
      WHERE ml.review_status = 'open'
        AND b.nightly_rate BETWEEN fn_parse_money(REPLACE(ml.price, '$', ''))
                               AND fn_parse_money(REPLACE(ml.price, '$', '')) * 1.25
      GROUP BY ml.raw_row_id) x ON x.raw_row_id = m.raw_row_id
SET m.price = REPLACE(m.price, '$', ''), m.review_status = 'fixed', m.reviewer_note = '$ was a typo, matches bookings';

-- 4e: listings pointing at a duplicate neighbourhood get released automatically
-- after the merge in section 1.

-- TEMPLATES (judgement calls):
-- Orphan host / neighbourhood: correct the id or drop the listing.
-- UPDATE manual_listings SET host_id = '1234', review_status = 'fixed' WHERE raw_row_id = 123;
-- UPDATE manual_listings SET review_status = 'rejected', reviewer_note = 'unknown host' WHERE raw_row_id = 123;
--
-- Conflicting duplicate (same listing_id, different price): keep one, reject the other.
-- SELECT raw_row_id, listing_id, price, updated_at FROM manual_listings
-- WHERE issue_summary LIKE '%conflicting_duplicate%' ORDER BY listing_id;
-- UPDATE manual_listings SET review_status = 'rejected' WHERE raw_row_id = 123;   -- the wrong one
-- UPDATE manual_listings SET review_status = 'approved' WHERE raw_row_id = 456;   -- the right one


-- #####################################################################
-- 5. BOOKINGS
-- Most bulk fixes use total_price = nights x nightly_rate + cleaning_fee:
-- if exactly one reading of the messy value makes the booking add up, that one wins.
-- #####################################################################

-- REVIEW
SELECT i.issue_code, i.severity, COUNT(DISTINCT i.raw_row_id) AS n_rows FROM manual_issues i
WHERE i.table_name = 'bookings' AND i.severity <> 'waiting' GROUP BY 1, 2 ORDER BY n_rows DESC;

-- Work table with every possible reading of each booking's dates and money.
DROP TABLE IF EXISTS tmp_booking_candidates;
CREATE TABLE tmp_booking_candidates (raw_row_id BIGINT UNSIGNED PRIMARY KEY)
SELECT raw_row_id,
       DATE(fn_parse_datetime(check_in, 'dmy'))  AS ci_dmy, DATE(fn_parse_datetime(check_in, 'mdy'))  AS ci_mdy,
       DATE(fn_parse_datetime(check_out, 'dmy')) AS co_dmy, DATE(fn_parse_datetime(check_out, 'mdy')) AS co_mdy,
       fn_parse_money(REPLACE(nightly_rate, '$', '')) AS rate,
       fn_parse_money(REPLACE(cleaning_fee, '$', '')) AS fee,
       fn_parse_money(REPLACE(total_price, '$', ''))  AS total,
       -- '1.234' read as thousands (1234), the decimal reading is just the number
       CAST(REPLACE(REGEXP_REPLACE(total_price, '[^0-9.]', ''), '.', '') AS DECIMAL(14,2)) AS total_thousands
FROM manual_bookings
WHERE review_status = 'open';

-- RESOLVE 5a: ambiguous check_in / check_out (03/04/2024). Try all four DD/MM - MM/DD
-- combinations, keep the booking only if exactly one makes the total add up.
UPDATE manual_bookings m
JOIN (SELECT c.raw_row_id, MIN(x.ci) AS new_ci, MIN(x.co) AS new_co
      FROM tmp_booking_candidates c
      JOIN (SELECT raw_row_id, ci_dmy AS ci, co_dmy AS co FROM tmp_booking_candidates
            UNION SELECT raw_row_id, ci_dmy, co_mdy FROM tmp_booking_candidates
            UNION SELECT raw_row_id, ci_mdy, co_dmy FROM tmp_booking_candidates
            UNION SELECT raw_row_id, ci_mdy, co_mdy FROM tmp_booking_candidates) x ON x.raw_row_id = c.raw_row_id
      JOIN manual_bookings mb ON mb.raw_row_id = c.raw_row_id
      WHERE EXISTS (SELECT 1 FROM manual_issues i WHERE i.table_name = 'bookings' AND i.raw_row_id = c.raw_row_id
                    AND i.issue_code = 'ambiguous_date' AND i.column_name IN ('check_in', 'check_out'))
        AND x.co > x.ci
        AND DATEDIFF(x.co, x.ci) * c.rate + c.fee = c.total
      GROUP BY c.raw_row_id
      HAVING COUNT(*) = 1) r ON r.raw_row_id = m.raw_row_id
SET m.check_in = r.new_ci, m.check_out = r.new_co,
    m.review_status = 'fixed', m.reviewer_note = 'date order chosen so the total adds up';

-- RESOLVE 5b: check_out before check_in -> swap (only if the swapped dates add up).
UPDATE manual_bookings m
JOIN (SELECT mb.raw_row_id, mb.check_in AS old_in, mb.check_out AS old_out
      FROM manual_bookings mb JOIN tmp_booking_candidates c ON c.raw_row_id = mb.raw_row_id
      WHERE mb.review_status = 'open' AND mb.issue_summary LIKE '%check_out_before_check_in%'
        AND DATEDIFF(c.ci_dmy, c.co_dmy) * c.rate + c.fee = c.total) x ON x.raw_row_id = m.raw_row_id
SET m.check_in = x.old_out, m.check_out = x.old_in, m.review_status = 'fixed', m.reviewer_note = 'swapped dates';

-- RESOLVE 5c: '$' instead of the booking currency. Drop it if the booking then adds up.
UPDATE manual_bookings m
JOIN tmp_booking_candidates c ON c.raw_row_id = m.raw_row_id
SET m.nightly_rate = REPLACE(m.nightly_rate, '$', ''), m.cleaning_fee = REPLACE(m.cleaning_fee, '$', ''),
    m.total_price = REPLACE(m.total_price, '$', ''),
    m.review_status = 'fixed', m.reviewer_note = '$ was a typo, total adds up'
WHERE m.review_status = 'open' AND m.issue_summary LIKE '%dollar_sign_vs_currency%'
  AND DATEDIFF(c.co_dmy, c.ci_dmy) * c.rate + c.fee = c.total;

-- RESOLVE 5d: total like '1.235' (thousands or decimal?). It was rounded, so accept the
-- thousands reading when within 1 of nights x rate + fee and store the exact total.
UPDATE manual_bookings m
JOIN tmp_booking_candidates c ON c.raw_row_id = m.raw_row_id
SET m.total_price = CAST(DATEDIFF(c.co_dmy, c.ci_dmy) * c.rate + c.fee AS CHAR),
    m.review_status = 'fixed', m.reviewer_note = '1.234 read as thousands'
WHERE m.review_status = 'open' AND m.issue_summary LIKE '%ambiguous_thousands_or_decimal%'
  AND c.co_dmy > c.ci_dmy
  AND ABS(DATEDIFF(c.co_dmy, c.ci_dmy) * c.rate + c.fee - c.total_thousands) < 1;

-- RESOLVE 5e: nightly rate 100x too big -> divide by 100 if the booking then adds up.
UPDATE manual_bookings m
JOIN tmp_booking_candidates c ON c.raw_row_id = m.raw_row_id
SET m.nightly_rate = CAST(c.rate / 100 AS DECIMAL(10,2)), m.review_status = 'fixed', m.reviewer_note = 'rate / 100'
WHERE m.review_status = 'open' AND m.issue_summary LIKE '%price_outlier%'
  AND DATEDIFF(c.co_dmy, c.ci_dmy) * CAST(c.rate / 100 AS DECIMAL(10,2)) + c.fee = c.total;

-- RESOLVE 5f: negative total -> drop the minus if the booking then adds up.
UPDATE manual_bookings m
JOIN tmp_booking_candidates c ON c.raw_row_id = m.raw_row_id
SET m.total_price = CAST(-c.total AS CHAR), m.review_status = 'fixed', m.reviewer_note = 'removed minus sign'
WHERE m.review_status = 'open' AND m.issue_summary LIKE '%negative_total%'
  AND DATEDIFF(c.co_dmy, c.ci_dmy) * c.rate + c.fee = -c.total;

-- RESOLVE 5g: total doesn't add up. Use nights x rate + fee when a payment charged exactly
-- that amount (rate and fee were right, the total was the typo).
UPDATE manual_bookings m
JOIN tmp_booking_candidates c ON c.raw_row_id = m.raw_row_id
SET m.total_price = CAST(DATEDIFF(c.co_dmy, c.ci_dmy) * c.rate + c.fee AS CHAR),
    m.review_status = 'fixed', m.reviewer_note = 'total recomputed, matches a payment'
WHERE m.review_status = 'open' AND m.issue_summary = 'total_does_not_match'
  AND EXISTS (SELECT 1 FROM stg_payments p
              WHERE p.booking_id = fn_parse_id(m.booking_id)
                AND p.amount = DATEDIFF(c.co_dmy, c.ci_dmy) * c.rate + c.fee);

-- RESOLVE 5h: missing status -> value 03 inferred from payments and reviews
-- (e.g. 'completed (has a review)' -> 'completed').
UPDATE manual_bookings m
JOIN manual_issues i ON i.table_name = 'bookings' AND i.raw_row_id = m.raw_row_id AND i.issue_code = 'status_missing'
SET m.status = SUBSTRING_INDEX(i.suggested_value, ' ', 1),
    m.review_status = 'fixed', m.reviewer_note = 'status inferred from payments/reviews'
WHERE m.review_status = 'open';

DROP TABLE IF EXISTS tmp_booking_candidates;

-- TEMPLATES (judgement calls):
-- Overlapping booking: check both bookings on the listing, then fix the dates or reject one.
-- SELECT b.* FROM manual_bookings m
-- JOIN airbnb_clean.bookings b ON b.listing_id = fn_parse_id(m.listing_id)
-- WHERE m.raw_row_id = 123 ORDER BY b.check_in;
-- UPDATE manual_bookings SET review_status = 'approved', reviewer_note = 'early check-in agreed' WHERE raw_row_id = 123;
--
-- Conflicting duplicate booking_id (two versions with a different status or num_guests):
-- SELECT raw_row_id, booking_id, status, num_guests FROM manual_bookings
-- WHERE issue_summary LIKE '%conflicting_duplicate%' ORDER BY booking_id;
-- UPDATE manual_bookings SET review_status = 'rejected' WHERE raw_row_id = 123;   -- wrong version
--
-- Orphan listing/guest id, zero-night stay: fix the value or reject.
-- UPDATE manual_bookings SET listing_id = '1234', review_status = 'fixed' WHERE raw_row_id = 123;


-- #####################################################################
-- 6. PAYMENTS
-- A payment makes sense when it is the booking total, the 30% deposit or the 70% balance
-- (or minus the total / half the total for a refund).
-- #####################################################################

-- REVIEW
SELECT i.issue_code, i.severity, COUNT(DISTINCT i.raw_row_id) AS n_rows FROM manual_issues i
WHERE i.table_name = 'payments' AND i.severity <> 'waiting' GROUP BY 1, 2 ORDER BY n_rows DESC;

DROP TABLE IF EXISTS tmp_payment_candidates;
CREATE TABLE tmp_payment_candidates (raw_row_id BIGINT UNSIGNED PRIMARY KEY)
SELECT m.raw_row_id, b.total_price, b.booking_date, b.check_out,
       fn_parse_datetime(m.payment_date, 'dmy') AS pd_dmy,
       fn_parse_datetime(m.payment_date, 'mdy') AS pd_mdy,
       fn_parse_money(REPLACE(m.amount, '$', '')) AS amount_no_dollar,
       CAST(REPLACE(REGEXP_REPLACE(m.amount, '[^0-9.]', ''), '.', '') AS DECIMAL(14,2)) AS amount_thousands
FROM manual_payments m
JOIN airbnb_clean.bookings b ON b.booking_id = fn_parse_id(m.booking_id)
WHERE m.review_status = 'open';

-- RESOLVE 6a: ambiguous payment date. Keep the reading between the booking date
-- (minus a day) and the snapshot date, if only one of the two fits.
UPDATE manual_payments m
JOIN tmp_payment_candidates c ON c.raw_row_id = m.raw_row_id
SET m.payment_date = IF(c.pd_dmy BETWEEN c.booking_date - INTERVAL 1 DAY AND @snapshot_date + INTERVAL 1 DAY, c.pd_dmy, c.pd_mdy),
    m.review_status = 'fixed', m.reviewer_note = 'only date reading after the booking date'
WHERE m.review_status = 'open' AND m.issue_summary = 'ambiguous_date'
  AND (c.pd_dmy BETWEEN c.booking_date - INTERVAL 1 DAY AND @snapshot_date + INTERVAL 1 DAY)
    + (c.pd_mdy BETWEEN c.booking_date - INTERVAL 1 DAY AND @snapshot_date + INTERVAL 1 DAY) = 1;

-- RESOLVE 6b: '$' amount -> drop the '$' if the amount matches the booking.
UPDATE manual_payments m
JOIN tmp_payment_candidates c ON c.raw_row_id = m.raw_row_id
SET m.amount = REPLACE(m.amount, '$', ''), m.review_status = 'fixed', m.reviewer_note = '$ was a typo, matches booking'
WHERE m.review_status = 'open' AND m.issue_summary = 'dollar_sign_vs_currency'
  AND (ABS(c.amount_no_dollar) = c.total_price
       OR ABS(ABS(c.amount_no_dollar) - c.total_price * 0.3) <= 0.01
       OR ABS(ABS(c.amount_no_dollar) - c.total_price * 0.7) <= 0.01
       OR ABS(ABS(c.amount_no_dollar) - c.total_price * 0.5) <= 0.01);

-- RESOLVE 6c: amount like '1.235' -> thousands reading if within 1 of an expected amount.
UPDATE manual_payments m
JOIN tmp_payment_candidates c ON c.raw_row_id = m.raw_row_id
SET m.amount = CAST(CASE WHEN ABS(c.amount_thousands - c.total_price) < 1 THEN c.total_price
                         WHEN ABS(c.amount_thousands - c.total_price * 0.7) < 1 THEN c.total_price - ROUND(c.total_price * 0.3, 2)
                         ELSE ROUND(c.total_price * 0.3, 2) END AS CHAR),
    m.review_status = 'fixed', m.reviewer_note = '1.234 read as thousands'
WHERE m.review_status = 'open' AND m.issue_summary = 'ambiguous_thousands_or_decimal'
  AND (ABS(c.amount_thousands - c.total_price) < 1
       OR ABS(c.amount_thousands - c.total_price * 0.3) < 1
       OR ABS(c.amount_thousands - c.total_price * 0.7) < 1);

DROP TABLE IF EXISTS tmp_payment_candidates;

-- TEMPLATES (money questions, decided by hand):
-- Reused transaction_ref (possible double charge): compare both payments, reject the copy.
-- SELECT raw_row_id, payment_id, booking_id, payment_date, amount, transaction_ref FROM manual_payments
-- WHERE issue_summary LIKE '%reused_transaction_ref%';
-- UPDATE manual_payments SET review_status = 'rejected', reviewer_note = 'double charge, refunded' WHERE raw_row_id = 123;
--
-- Amount doesn't reconcile / paid before booked / currency differs from the booking:
-- UPDATE manual_payments SET amount = '199.50', review_status = 'fixed' WHERE raw_row_id = 123;
-- UPDATE manual_payments SET review_status = 'approved', reviewer_note = 'partial goodwill refund' WHERE raw_row_id = 123;


-- #####################################################################
-- 7. REVIEWS
-- #####################################################################

-- REVIEW
SELECT i.issue_code, i.severity, COUNT(DISTINCT i.raw_row_id) AS n_rows FROM manual_issues i
WHERE i.table_name = 'reviews' AND i.severity <> 'waiting' GROUP BY 1, 2 ORDER BY n_rows DESC;

SELECT raw_row_id, review_id, booking_id, comments FROM manual_reviews
WHERE review_status = 'open' AND issue_summary LIKE '%junk_review%';

-- RESOLVE 7a: test / junk text ('test', 'asdfgh', '.') is not a real review.
UPDATE manual_reviews SET review_status = 'rejected', reviewer_note = 'test/junk review'
WHERE review_status = 'open' AND issue_summary LIKE '%junk_review%';

-- RESOLVE 7b: second review for a booking that already has one. README rule is
-- one review per booking, the first one stays in clean.
UPDATE manual_reviews SET review_status = 'rejected', reviewer_note = 'second review for the same booking'
WHERE review_status = 'open' AND issue_summary = 'second_review_for_booking';

-- RESOLVE 7c: score 6-10 on a 1-5 scale, most likely out of 10, so halve it (03 suggested the value).
UPDATE manual_reviews m
JOIN (SELECT raw_row_id,
             MAX(CASE WHEN column_name = 'rating' THEN SUBSTRING_INDEX(suggested_value, ' ', 1) END) AS rating,
             MAX(CASE WHEN column_name = 'cleanliness' THEN SUBSTRING_INDEX(suggested_value, ' ', 1) END) AS cleanliness,
             MAX(CASE WHEN column_name = 'communication' THEN SUBSTRING_INDEX(suggested_value, ' ', 1) END) AS communication,
             MAX(CASE WHEN column_name = 'value' THEN SUBSTRING_INDEX(suggested_value, ' ', 1) END) AS val
      FROM manual_issues
      WHERE table_name = 'reviews' AND issue_code = 'score_out_of_range' AND suggested_value IS NOT NULL
      GROUP BY raw_row_id) s ON s.raw_row_id = m.raw_row_id
SET m.rating = COALESCE(s.rating, m.rating), m.cleanliness = COALESCE(s.cleanliness, m.cleanliness),
    m.communication = COALESCE(s.communication, m.communication), m.`value` = COALESCE(s.val, m.`value`),
    m.review_status = 'fixed', m.reviewer_note = '10-point score halved'
WHERE m.review_status = 'open' AND m.issue_summary = 'score_out_of_range';

-- TEMPLATES:
-- listing_id / guest_id doesn't match the booking: 03 suggests the booking's value.
-- SELECT m.raw_row_id, m.booking_id, m.listing_id, m.guest_id, m.suggested_fix FROM manual_reviews m
-- WHERE m.issue_summary LIKE '%does_not_match_booking%';
-- UPDATE manual_reviews SET listing_id = '1234', review_status = 'fixed' WHERE raw_row_id = 123;


-- #####################################################################
-- 8. LISTING_AMENITIES
-- Orphans only (amenity or listing id doesn't exist). Usually just dropped:
-- UPDATE manual_listing_amenities SET review_status = 'rejected', reviewer_note = 'unknown id'
-- WHERE review_status = 'open' AND issue_summary = 'orphan_reference';
-- Rows waiting on their listing get released automatically.
-- #####################################################################


-- #####################################################################
-- 8b. WORKED EXAMPLES: four judgement calls done by hand
-- Each one: evidence (SELECT), decision (UPDATE).
-- WHERE uses both raw_row_id and the business id, so nothing changes if the raw
-- load ever numbers the rows differently.
-- #####################################################################

-- ---------------------------------------------------------------------
-- Example 1. Overlapping booking: booking 46962 on listing 2686
-- ---------------------------------------------------------------------
-- Evidence: the listing's stays around that date.
SELECT booking_id, check_in, check_out, status, nights, total_price
FROM airbnb_clean.bookings WHERE listing_id = 2686 AND check_in BETWEEN '2024-09-01' AND '2024-11-30'
ORDER BY check_in;
SELECT raw_row_id, booking_id, check_in, check_out, nightly_rate, total_price FROM manual_bookings WHERE booking_id = '46962';
-- 45727 runs 21-23 Sep, 46962 says 22-25 Sep (3 nights). Next stay starts 24 Oct and the
-- guest's review is dated 15 Oct, so the stay fits right after 45727 ends.
-- Decision: move it to 23-26 Sep. Still 3 nights at the same rate, total still adds up.
UPDATE manual_bookings
SET check_in = '2024-09-23', check_out = '2024-09-26',
    review_status = 'fixed', reviewer_note = 'overlap: moved to start when booking 45727 ends'
WHERE raw_row_id = 214 AND booking_id = '46962' AND review_status = 'open';

-- ---------------------------------------------------------------------
-- Example 2. Double charge: payment 76965 reuses the transaction ref of payment 52397
-- ---------------------------------------------------------------------
SELECT payment_id, booking_id, payment_date, amount, payment_status, transaction_ref
FROM airbnb_clean.payments WHERE transaction_ref = 'TXN-BE9D950F11';
SELECT raw_row_id, payment_id, booking_id, payment_date, amount, transaction_ref FROM manual_payments WHERE payment_id = '76965';
-- Same booking (46529), same amount (995.00), same reference, but dated 2026, 19 months after
-- the real payment. A processor wouldn't reuse a reference, so it's a duplicate record.
-- Decision: reject the copy.
UPDATE manual_payments
SET review_status = 'rejected', reviewer_note = 'duplicate record of payment 52397 (same ref, amount, booking)'
WHERE raw_row_id = 616 AND payment_id = '76965' AND review_status = 'open';

-- ---------------------------------------------------------------------
-- Example 3. Orphan reference: booking 65393 points at listing 19851, which doesn't exist
-- ---------------------------------------------------------------------
SELECT raw_row_id, booking_id, listing_id, guest_id, check_in, check_out, nightly_rate, total_price
FROM manual_bookings WHERE booking_id = '65393';
-- The guest's review of this booking names the listing:
SELECT review_id, booking_id, listing_id, guest_id FROM stg_reviews WHERE booking_id = 65393;
-- Listing 1313 is 122.99 a night (same as the booking's rate), sleeps 2 (= num_guests)
-- and is free 29 Jan - 3 Feb 2026:
SELECT listing_id, price, accommodates FROM airbnb_clean.listings WHERE listing_id = 1313;
SELECT booking_id, check_in, check_out FROM airbnb_clean.bookings
WHERE listing_id = 1313 AND check_in BETWEEN '2026-01-01' AND '2026-02-28' ORDER BY check_in;
-- Decision: listing id was mistyped, use 1313. The review waiting on this booking gets released too.
UPDATE manual_bookings
SET listing_id = '1313', review_status = 'fixed', reviewer_note = 'listing id from the review; price and dates fit'
WHERE raw_row_id = 210 AND booking_id = '65393' AND review_status = 'open';

-- ---------------------------------------------------------------------
-- Example 4. Conflicting duplicate: booking 1335 appears twice, 'completed' and 'cancelled'
-- ---------------------------------------------------------------------
SELECT raw_row_id, booking_id, status, num_guests, total_price FROM manual_bookings WHERE booking_id = '1335';
SELECT payment_id, amount, payment_status FROM stg_payments WHERE booking_id = 1335;
SELECT review_id, rating, review_date FROM stg_reviews WHERE booking_id = 1335;
-- Completed payment, no refund, and a review after the stay. A cancelled booking
-- wouldn't have a review or an unrefunded payment.
-- Decision: reject the 'cancelled' row. With one row left for 1335 the conflict is gone
-- and the 'completed' row loads on the next run as it is.
UPDATE manual_bookings
SET review_status = 'rejected', reviewer_note = 'wrong version: booking has a review and an unrefunded payment'
WHERE raw_row_id = 60433 AND booking_id = '1335' AND review_status = 'open';

-- After rerunning 03, check all four are in clean (and the copy isn't):
-- SELECT booking_id, listing_id, check_in, check_out, status FROM airbnb_clean.bookings WHERE booking_id IN (46962, 65393, 1335);
-- SELECT COUNT(*) FROM airbnb_clean.payments WHERE payment_id = 76965;   -- 0


-- #####################################################################
-- 9. SUMMARY OF CHANGES   (then rerun 03_cleaning_pipeline.sql)
-- #####################################################################
SELECT 'neighbourhoods' AS tbl, review_status, reviewer_note, COUNT(*) AS n_rows FROM manual_neighbourhoods WHERE review_status <> 'open' GROUP BY 2,3
UNION ALL SELECT 'hosts', review_status, reviewer_note, COUNT(*) FROM manual_hosts WHERE review_status <> 'open' GROUP BY 2,3
UNION ALL SELECT 'guests', review_status, reviewer_note, COUNT(*) FROM manual_guests WHERE review_status <> 'open' GROUP BY 2,3
UNION ALL SELECT 'listings', review_status, reviewer_note, COUNT(*) FROM manual_listings WHERE review_status <> 'open' GROUP BY 2,3
UNION ALL SELECT 'bookings', review_status, reviewer_note, COUNT(*) FROM manual_bookings WHERE review_status <> 'open' GROUP BY 2,3
UNION ALL SELECT 'payments', review_status, reviewer_note, COUNT(*) FROM manual_payments WHERE review_status <> 'open' GROUP BY 2,3
UNION ALL SELECT 'reviews', review_status, reviewer_note, COUNT(*) FROM manual_reviews WHERE review_status <> 'open' GROUP BY 2,3
ORDER BY tbl, review_status, n_rows DESC;

-- After rerunning 03: 'fixed' rows that still didn't pass are back to 'open'
-- with the edits kept:
-- SELECT * FROM manual_bookings WHERE reviewer_note IS NOT NULL AND review_status = 'open';
