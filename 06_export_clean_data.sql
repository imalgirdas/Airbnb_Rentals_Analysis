-- =====================================================================
-- 06_export_clean_data.sql  -  reporting views + CSV export   (MySQL 8.0)
-- =====================================================================
-- Run order: 01 -> 02 -> 03 -> (04 -> 03) -> 06.
-- Normally run through 06_export_clean_data.bat, which writes the CSVs to Clean_data. Safe to rerun.
--
-- Creates in airbnb_clean:
--   fx_rates            currency -> EUR rate
--   rpt_bookings        1 row per booking, with listing / city / host / guest / review
--   rpt_listings        1 row per listing, with revenue, stays and rating
--   rpt_city_month      1 row per city per month: occupancy, revenue, cancellations
--   rpt_reviews         1 row per review, with city, price and price band
--   sp_export_csv(name) prints a table or view as CSV lines (header first)
--
-- Views are wide and flat so Looker Studio needs no joins, and they share field names
-- (city, neighbourhood, room_type, host_type) so one filter works on every page.
-- *_eur columns convert GBP at a fixed 1 GBP = 1.17 EUR (fx_rates). Original currency kept too.
-- =====================================================================

USE airbnb_clean;

-- ---------------------------------------------------------------------
-- 1. Exchange rates
-- ---------------------------------------------------------------------
DROP TABLE IF EXISTS fx_rates;
CREATE TABLE fx_rates (
  currency CHAR(3)       PRIMARY KEY,
  to_eur   DECIMAL(8,4)  NOT NULL
);
INSERT INTO fx_rates VALUES ('EUR', 1.0000), ('GBP', 1.1700);


-- ---------------------------------------------------------------------
-- 2. rpt_bookings: the main "fact" table of the dashboard
-- ---------------------------------------------------------------------
-- Flags are 0/1 so Looker can SUM/AVG them (AVG(is_cancelled) = cancellation rate).
CREATE OR REPLACE VIEW rpt_bookings AS
SELECT b.booking_id,
       DATE(b.booking_date)                                         AS booking_date,
       b.check_in,
       b.check_out,
       b.check_in - INTERVAL (DAY(b.check_in) - 1) DAY              AS stay_month,   -- 1st of the month
       b.nights,
       b.num_guests,
       b.status,
       b.channel,
       DATEDIFF(b.check_in, DATE(b.booking_date))                   AS lead_time_days,
       CASE WHEN DATEDIFF(b.check_in, DATE(b.booking_date)) <= 7  THEN '1. 0-7 days'
            WHEN DATEDIFF(b.check_in, DATE(b.booking_date)) <= 30 THEN '2. 8-30 days'
            WHEN DATEDIFF(b.check_in, DATE(b.booking_date)) <= 90 THEN '3. 31-90 days'
            ELSE '4. 90+ days' END                                  AS lead_time_bucket,
       b.currency,
       b.nightly_rate,
       b.total_price,
       ROUND(b.nightly_rate * fx.to_eur, 2)                         AS nightly_rate_eur,
       ROUND(b.total_price  * fx.to_eur, 2)                         AS total_price_eur,
       -- revenue = completed stays only (same rule as 05)
       CASE WHEN b.status = 'completed' THEN ROUND(b.total_price * fx.to_eur, 2) ELSE 0 END AS revenue_eur,
       CASE WHEN b.status = 'completed' THEN b.nights ELSE 0 END    AS nights_stayed,
       (b.status = 'completed') + 0                                 AS is_completed,
       (b.status = 'cancelled') + 0                                 AS is_cancelled,
       (b.status = 'no_show')   + 0                                 AS is_no_show,
       l.listing_id,
       l.room_type,
       l.property_type,
       n.neighbourhood_name                                         AS neighbourhood,
       n.city,
       c.country_name                                               AS country,
       h.host_id,
       CONCAT_WS(' ', h.first_name, h.last_name)                    AS host_name,
       IF(h.is_superhost = 1, 'Superhost', 'Regular')               AS host_type,
       b.guest_id,
       g.country                                                    AS guest_country,
       r.rating                                                     AS review_rating, -- empty = no review
       (r.review_id IS NOT NULL) + 0                                AS has_review
FROM bookings b
JOIN listings l        ON l.listing_id = b.listing_id
JOIN neighbourhoods n  ON n.neighbourhood_id = l.neighbourhood_id
JOIN cities c          ON c.city = n.city
JOIN fx_rates fx       ON fx.currency = b.currency
JOIN hosts h           ON h.host_id = l.host_id
LEFT JOIN guests g     ON g.guest_id = b.guest_id
LEFT JOIN reviews r    ON r.booking_id = b.booking_id;


-- ---------------------------------------------------------------------
-- 3. rpt_listings: one row per listing (map, neighbourhood table, hosts, price bands)
-- ---------------------------------------------------------------------
-- lat_lng is "lat,lng" in one field, which Looker needs for the Google Map.
-- price_band = NTILE(5) within each city, Band 1 = cheapest 20%.
CREATE OR REPLACE VIEW rpt_listings AS
WITH stays AS (
  SELECT listing_id,
         COUNT(*)                                   AS bookings,
         SUM(status = 'completed')                  AS stays,
         SUM(CASE WHEN status = 'completed' THEN nights ELSE 0 END)      AS nights_stayed,
         SUM(CASE WHEN status = 'completed' THEN total_price ELSE 0 END) AS revenue_local
  FROM bookings GROUP BY listing_id
),
rev AS (
  SELECT listing_id, COUNT(*) AS reviews, AVG(rating) AS avg_rating
  FROM reviews GROUP BY listing_id
)
SELECT l.listing_id,
       l.title,
       l.property_type,
       l.room_type,
       l.accommodates,
       l.bedrooms,
       l.status                                             AS listing_status,
       YEAR(l.created_at)                                   AS listed_year,  -- number, not a date, so the
                                                            -- date filter doesn't hide old listings
       IF(l.instant_bookable = 1, 'Yes', 'No')              AS instant_bookable,
       n.neighbourhood_name                                 AS neighbourhood,
       n.city,
       l.latitude,
       l.longitude,
       CONCAT(l.latitude, ',', l.longitude)                 AS lat_lng,
       h.host_id,
       CONCAT_WS(' ', h.first_name, h.last_name)            AS host_name,
       IF(h.is_superhost = 1, 'Superhost', 'Regular')       AS host_type,
       h.response_rate                                      AS host_response_rate,
       l.currency,
       l.price,
       ROUND(l.price * fx.to_eur, 2)                        AS price_eur,
       CASE WHEN l.price IS NOT NULL               -- 58 listings have no price, so no band
            THEN CONCAT('Band ', NTILE(5) OVER (PARTITION BY n.city, l.price IS NULL ORDER BY l.price))
       END                                                  AS price_band,
       COALESCE(s.bookings, 0)                              AS bookings,
       COALESCE(s.stays, 0)                                 AS stays,
       COALESCE(s.nights_stayed, 0)                         AS nights_stayed,
       ROUND(COALESCE(s.revenue_local, 0) * fx.to_eur, 2)   AS revenue_eur,
       COALESCE(r.reviews, 0)                               AS reviews,
       ROUND(r.avg_rating, 2)                               AS avg_rating        -- empty = never reviewed
FROM listings l
JOIN neighbourhoods n ON n.neighbourhood_id = l.neighbourhood_id
JOIN hosts h          ON h.host_id = l.host_id
JOIN fx_rates fx      ON fx.currency = l.currency
LEFT JOIN stays s     ON s.listing_id = l.listing_id
LEFT JOIN rev r       ON r.listing_id = l.listing_id;


-- ---------------------------------------------------------------------
-- 4. rpt_city_month: occupancy and revenue per city per month (Jan 2022 - Dec 2025)
-- ---------------------------------------------------------------------
-- nights_available is pre-computed here (same logic as Q3 in 05). Both parts are exported so
-- occupancy = SUM(nights_booked) / SUM(nights_available) stays right when filtering in Looker.
-- Ends at Dec 2025: generated bookings drop to a few hundred a month in 2026.
CREATE OR REPLACE VIEW rpt_city_month AS
WITH RECURSIVE months AS (
  SELECT DATE('2022-01-01') AS month_start
  UNION ALL
  SELECT month_start + INTERVAL 1 MONTH FROM months WHERE month_start < '2025-12-01'
),
active AS (
  SELECT l.listing_id, n.city, l.created_at
  FROM listings l JOIN neighbourhoods n ON n.neighbourhood_id = l.neighbourhood_id
  WHERE l.status <> 'delisted'
),
capacity AS (
  SELECT m.month_start, a.city,
         COUNT(*)                            AS active_listings,
         COUNT(*) * DAY(LAST_DAY(m.month_start)) AS nights_available
  FROM months m
  JOIN active a ON a.created_at IS NULL OR a.created_at < m.month_start
  GROUP BY m.month_start, a.city
),
booked AS (                                  -- nights inside the month only
  SELECT m.month_start, a.city,
         SUM(GREATEST(0, DATEDIFF(LEAST(b.check_out, m.month_start + INTERVAL 1 MONTH),
                                  GREATEST(b.check_in, m.month_start)))) AS nights_booked
  FROM months m
  JOIN bookings b ON b.check_in < m.month_start + INTERVAL 1 MONTH AND b.check_out > m.month_start
                 AND b.status IN ('completed', 'no_show')
  JOIN active a   ON a.listing_id = b.listing_id
  GROUP BY m.month_start, a.city
),
money AS (                                   -- stays counted in their check-in month
  SELECT b.check_in - INTERVAL (DAY(b.check_in) - 1) DAY AS month_start, n.city,
         COUNT(*)                                        AS bookings,
         SUM(b.status = 'completed')                     AS stays,
         SUM(b.status = 'cancelled')                     AS cancellations,
         ROUND(SUM(CASE WHEN b.status = 'completed' THEN b.total_price * fx.to_eur ELSE 0 END), 2) AS revenue_eur
  FROM bookings b
  JOIN listings l       ON l.listing_id = b.listing_id
  JOIN neighbourhoods n ON n.neighbourhood_id = l.neighbourhood_id
  JOIN fx_rates fx      ON fx.currency = b.currency
  GROUP BY 1, 2
)
SELECT c.month_start                                         AS month,
       c.city,
       c.active_listings,
       c.nights_available,
       COALESCE(bk.nights_booked, 0)                         AS nights_booked,
       ROUND(COALESCE(bk.nights_booked, 0) / c.nights_available, 4) AS occupancy_rate, -- 0.0150 = 1.5%
       COALESCE(mo.bookings, 0)                              AS bookings,
       COALESCE(mo.stays, 0)                                 AS stays,
       COALESCE(mo.cancellations, 0)                         AS cancellations,
       COALESCE(mo.revenue_eur, 0)                           AS revenue_eur
FROM capacity c
LEFT JOIN booked bk ON bk.month_start = c.month_start AND bk.city = c.city
LEFT JOIN money  mo ON mo.month_start = c.month_start AND mo.city = c.city;


-- ---------------------------------------------------------------------
-- 5. rpt_reviews: one row per review, with listing context
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW rpt_reviews AS
SELECT r.review_id,
       r.review_date,
       r.booking_id,
       r.rating,
       r.cleanliness,
       r.communication,
       r.value                                   AS value_for_money,
       (r.rating = 5) + 0                        AS is_five_star,
       rl.listing_id,
       rl.city,
       rl.neighbourhood,
       rl.room_type,
       rl.host_type,
       rl.price_eur,
       rl.price_band,
       r.comments
FROM reviews r
JOIN rpt_listings rl ON rl.listing_id = r.listing_id;


-- ---------------------------------------------------------------------
-- 6. sp_export_csv: print any table/view of airbnb_clean as CSV text
-- ---------------------------------------------------------------------
-- Not using INTO OUTFILE: on Windows secure_file_priv only allows MySQL's Uploads folder.
-- Instead it returns CSV lines and the .bat redirects them into a file.
--
-- Column formatting (NULL -> empty for all):
--   numbers as they are, dates YYYY-MM-DD, datetimes YYYY-MM-DD HH:MM:SS,
--   text in double quotes with any inner " doubled
-- Result 1 = header line, result 2 = data lines.
DROP PROCEDURE IF EXISTS sp_export_csv;
DELIMITER $$
CREATE PROCEDURE sp_export_csv(IN p_table VARCHAR(64))
BEGIN
  DECLARE v_header TEXT;
  DECLARE v_cols   TEXT;

  SET SESSION group_concat_max_len = 1000000;

  SELECT GROUP_CONCAT(column_name ORDER BY ordinal_position SEPARATOR ','),
         GROUP_CONCAT(
           CASE
             WHEN data_type IN ('tinyint','smallint','mediumint','int','bigint','decimal','float','double')
               THEN CONCAT('IFNULL(`', column_name, '`, '''')')
             WHEN data_type = 'date'
               THEN CONCAT('IFNULL(DATE_FORMAT(`', column_name, '`, ''%Y-%m-%d''), '''')')
             WHEN data_type IN ('datetime','timestamp')
               THEN CONCAT('IFNULL(DATE_FORMAT(`', column_name, '`, ''%Y-%m-%d %H:%i:%s''), '''')')
             ELSE CONCAT('IFNULL(CONCAT(''"'', REPLACE(`', column_name, '`, ''"'', ''""''), ''"''), '''')')
           END
           ORDER BY ordinal_position SEPARATOR ', ')
    INTO v_header, v_cols
  FROM information_schema.columns
  WHERE table_schema = 'airbnb_clean' AND table_name = p_table;

  IF v_cols IS NULL THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'sp_export_csv: no such table or view in airbnb_clean';
  END IF;

  SELECT v_header AS csv_line;                                    -- header row

  SET @sql = CONCAT('SELECT CONCAT_WS('','', ', v_cols, ') AS csv_line FROM airbnb_clean.`', p_table, '`');
  PREPARE stmt FROM @sql;
  EXECUTE stmt;                                                   -- data rows
  DEALLOCATE PREPARE stmt;
END$$
DELIMITER ;

-- Test: CALL sp_export_csv('fx_rates');
SELECT 'rpt_bookings' AS view_name, COUNT(*) AS row_count FROM rpt_bookings
UNION ALL SELECT 'rpt_listings',   COUNT(*) FROM rpt_listings
UNION ALL SELECT 'rpt_city_month', COUNT(*) FROM rpt_city_month
UNION ALL SELECT 'rpt_reviews',    COUNT(*) FROM rpt_reviews;
