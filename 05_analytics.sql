-- =====================================================================
-- 05_analytics.sql  -  business questions on airbnb_clean   (MySQL 8.0)
-- =====================================================================
-- Read-only, each query runs on its own.
--
--   "C:\Program Files\MySQL\MySQL Server 8.0\bin\mysql.exe" --default-character-set=utf8mb4 -u root -p -t < 05_analytics.sql
--
-- Notes:
--   * London is GBP, the other cities EUR, so money is always grouped by city.
--   * Revenue = total_price of completed bookings. Booked value also includes confirmed.
--   * Data snapshot is 2026-11-19, so 2025 is the last full year.
-- =====================================================================

USE airbnb_clean;


-- ---------------------------------------------------------------------
-- Q1. City overview (JOIN + GROUP BY + conditional aggregation)
-- Size of each market and share of bookings that actually complete.
-- ---------------------------------------------------------------------
SELECT n.city,
       c.currency,
       COUNT(DISTINCT l.listing_id)                                   AS listings,
       COUNT(*)                                                       AS bookings,
       SUM(b.status = 'completed')                                    AS completed,
       ROUND(100 * AVG(b.status = 'cancelled'), 1)                    AS cancel_pct,
       ROUND(SUM(CASE WHEN b.status = 'completed' THEN b.total_price END))  AS revenue,
       ROUND(AVG(CASE WHEN b.status = 'completed' THEN b.nightly_rate END), 2) AS avg_nightly_rate,
       ROUND(AVG(b.nights), 1)                                        AS avg_nights
FROM bookings b
JOIN listings l        ON l.listing_id = b.listing_id
JOIN neighbourhoods n  ON n.neighbourhood_id = l.neighbourhood_id
JOIN cities c          ON c.city = n.city
GROUP BY n.city, c.currency
ORDER BY revenue DESC;


-- ---------------------------------------------------------------------
-- Q2. Revenue by neighbourhood, ranked within each city (CTE + RANK + share of total)
-- ---------------------------------------------------------------------
WITH nbh AS (
  SELECT n.city, n.neighbourhood_name,
         COUNT(DISTINCT l.listing_id) AS listings,
         SUM(b.total_price)           AS revenue
  FROM bookings b
  JOIN listings l       ON l.listing_id = b.listing_id
  JOIN neighbourhoods n ON n.neighbourhood_id = l.neighbourhood_id
  WHERE b.status = 'completed'
  GROUP BY n.city, n.neighbourhood_name
)
SELECT city, neighbourhood_name, listings,
       ROUND(revenue)                                                     AS revenue,
       ROUND(revenue / listings)                                          AS revenue_per_listing,
       RANK() OVER (PARTITION BY city ORDER BY revenue DESC)              AS rank_in_city,
       ROUND(100 * revenue / SUM(revenue) OVER (PARTITION BY city), 1)    AS pct_of_city
FROM nbh
ORDER BY city, rank_in_city;


-- ---------------------------------------------------------------------
-- Q3. Occupancy rate by city and month, 2025 (RECURSIVE CTE calendar + date overlap)
-- Occupancy = nights booked / nights available. Stays crossing a month end are split by month.
-- Comes out at about 1-2% because the synthetic data has only ~5 booked nights per listing a year.
-- ---------------------------------------------------------------------
WITH RECURSIVE months AS (
  SELECT DATE('2025-01-01') AS m_start
  UNION ALL
  SELECT m_start + INTERVAL 1 MONTH FROM months WHERE m_start < '2025-12-01'
),
active AS (                     -- listings live during the month (created before it, not delisted)
  SELECT l.listing_id, n.city, l.created_at
  FROM listings l JOIN neighbourhoods n ON n.neighbourhood_id = l.neighbourhood_id
  WHERE l.status <> 'delisted'
),
booked AS (
  SELECT m.m_start, a.city,
         SUM(GREATEST(0, DATEDIFF(LEAST(b.check_out, m.m_start + INTERVAL 1 MONTH),
                                  GREATEST(b.check_in, m.m_start)))) AS nights_booked
  FROM months m
  JOIN bookings b ON b.check_in < m.m_start + INTERVAL 1 MONTH AND b.check_out > m.m_start
                 AND b.status IN ('completed', 'no_show')
  JOIN active a   ON a.listing_id = b.listing_id
  GROUP BY m.m_start, a.city
),
capacity AS (
  SELECT m.m_start, a.city,
         COUNT(*) * DAY(LAST_DAY(m.m_start)) AS nights_available
  FROM months m
  JOIN active a ON a.created_at IS NULL OR a.created_at < m.m_start
  GROUP BY m.m_start, a.city
)
SELECT DATE_FORMAT(c.m_start, '%Y-%m') AS month, c.city,
       b.nights_booked, c.nights_available,
       ROUND(100 * b.nights_booked / c.nights_available, 1) AS occupancy_pct
FROM capacity c
JOIN booked b ON b.m_start = c.m_start AND b.city = c.city
ORDER BY c.city, c.m_start;


-- ---------------------------------------------------------------------
-- Q4. Top 10 hosts per city by revenue (CTE + DENSE_RANK, filter on a window result)
-- Ranked in a CTE first because a window result can't be filtered in WHERE.
-- ---------------------------------------------------------------------
WITH host_rev AS (
  SELECT n.city, h.host_id,
         CONCAT(h.first_name, ' ', COALESCE(h.last_name, '')) AS host_name,
         h.is_superhost,
         COUNT(DISTINCT l.listing_id) AS listings,
         COUNT(*)                     AS stays,
         SUM(b.total_price)           AS revenue
  FROM bookings b
  JOIN listings l       ON l.listing_id = b.listing_id
  JOIN hosts h          ON h.host_id = l.host_id
  JOIN neighbourhoods n ON n.neighbourhood_id = l.neighbourhood_id
  WHERE b.status = 'completed'
  GROUP BY n.city, h.host_id, host_name, h.is_superhost
),
ranked AS (
  SELECT host_rev.*, DENSE_RANK() OVER (PARTITION BY city ORDER BY revenue DESC) AS rnk
  FROM host_rev
)
SELECT r.city, r.rnk, r.host_id, r.host_name, IF(r.is_superhost, 'yes', 'no') AS superhost,
       r.listings, r.stays, ROUND(r.revenue) AS revenue,
       ROUND(AVG(rv.rating), 2) AS avg_rating
FROM ranked r
LEFT JOIN listings l ON l.host_id = r.host_id
LEFT JOIN reviews rv ON rv.listing_id = l.listing_id
WHERE r.rnk <= 10
GROUP BY r.city, r.rnk, r.host_id, r.host_name, r.is_superhost, r.listings, r.stays, r.revenue
ORDER BY r.city, r.rnk;


-- ---------------------------------------------------------------------
-- Q5. Does a higher price get better reviews? (NTILE price bands within each city)
-- Price bands are per city, so GBP and EUR prices never get compared.
-- ---------------------------------------------------------------------
WITH priced AS (
  SELECT l.listing_id, n.city, l.price,
         NTILE(5) OVER (PARTITION BY n.city ORDER BY l.price) AS price_band
  FROM listings l JOIN neighbourhoods n ON n.neighbourhood_id = l.neighbourhood_id
  WHERE l.price IS NOT NULL
)
SELECT p.city, p.price_band,
       MIN(p.price) AS min_price, MAX(p.price) AS max_price,
       COUNT(r.review_id)                 AS reviews,
       ROUND(AVG(r.rating), 2)            AS avg_rating,
       ROUND(AVG(r.cleanliness), 2)       AS avg_cleanliness,
       ROUND(AVG(r.`value`), 2)           AS avg_value_for_money,
       ROUND(100 * AVG(r.rating = 5), 1)  AS pct_five_star
FROM priced p
JOIN reviews r ON r.listing_id = p.listing_id
GROUP BY p.city, p.price_band
ORDER BY p.city, p.price_band;


-- ---------------------------------------------------------------------
-- Q6. Seasonality: stays by check-in month, with year-over-year change (LAG)
-- ---------------------------------------------------------------------
WITH monthly AS (
  SELECT YEAR(check_in) AS yr, MONTH(check_in) AS mon,
         COUNT(*)                 AS stays,
         ROUND(AVG(nightly_rate), 2) AS avg_rate
  FROM bookings
  WHERE status = 'completed' AND check_in >= '2023-01-01' AND check_in < '2026-01-01'
  GROUP BY YEAR(check_in), MONTH(check_in)
)
SELECT yr, mon, stays, avg_rate,
       LAG(stays) OVER (PARTITION BY mon ORDER BY yr) AS stays_last_year,
       ROUND(100 * (stays / LAG(stays) OVER (PARTITION BY mon ORDER BY yr) - 1), 1) AS yoy_pct,
       -- vs that year's average month
       ROUND(stays / AVG(stays) OVER (PARTITION BY yr), 2) AS seasonal_index
FROM monthly
ORDER BY yr, mon;


-- ---------------------------------------------------------------------
-- Q7. Revenue trend: monthly revenue per city, running total and 3-month moving average
-- (window frames: ROWS BETWEEN ...)
-- ---------------------------------------------------------------------
WITH m AS (
  SELECT n.city, DATE_FORMAT(b.check_in, '%Y-%m') AS month, SUM(b.total_price) AS revenue
  FROM bookings b
  JOIN listings l       ON l.listing_id = b.listing_id
  JOIN neighbourhoods n ON n.neighbourhood_id = l.neighbourhood_id
  WHERE b.status = 'completed' AND b.check_in >= '2025-01-01' AND b.check_in < '2026-01-01'
  GROUP BY n.city, month
)
SELECT city, month, ROUND(revenue) AS revenue,
       ROUND(SUM(revenue) OVER (PARTITION BY city ORDER BY month
                                ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)) AS running_total,
       ROUND(AVG(revenue) OVER (PARTITION BY city ORDER BY month
                                ROWS BETWEEN 2 PRECEDING AND CURRENT ROW))         AS moving_avg_3m
FROM m
ORDER BY city, month;


-- ---------------------------------------------------------------------
-- Q8. Booking lead time and cancellations by channel (CASE buckets)
-- Lead time = days from booking to check-in.
-- ---------------------------------------------------------------------
SELECT channel,
       CASE WHEN DATEDIFF(check_in, booking_date) <= 7  THEN '1. 0-7 days'
            WHEN DATEDIFF(check_in, booking_date) <= 30 THEN '2. 8-30 days'
            WHEN DATEDIFF(check_in, booking_date) <= 90 THEN '3. 31-90 days'
            ELSE '4. 90+ days' END                   AS lead_time,
       COUNT(*)                                      AS bookings,
       ROUND(100 * AVG(status = 'cancelled'), 1)     AS cancel_pct,
       ROUND(AVG(nightly_rate), 2)                   AS avg_rate_mixed_ccy
FROM bookings
WHERE booking_date IS NOT NULL AND status IS NOT NULL
GROUP BY channel, lead_time
ORDER BY channel, lead_time;


-- ---------------------------------------------------------------------
-- Q9. Guest cohorts: first-stay year and how many came back later (CTE + MIN() OVER)
-- 2025 cohort looks low because the data ends in early 2026.
-- ---------------------------------------------------------------------
WITH stays AS (
  SELECT guest_id, YEAR(check_in) AS yr,
         MIN(YEAR(check_in)) OVER (PARTITION BY guest_id) AS cohort
  FROM bookings
  WHERE status = 'completed'
)
SELECT cohort,
       COUNT(DISTINCT guest_id)                                        AS guests,
       COUNT(DISTINCT CASE WHEN yr = cohort + 1 THEN guest_id END)     AS back_next_year,
       ROUND(100 * COUNT(DISTINCT CASE WHEN yr = cohort + 1 THEN guest_id END)
                 / COUNT(DISTINCT guest_id), 1)                        AS retention_y1_pct,
       COUNT(DISTINCT CASE WHEN yr > cohort THEN guest_id END)         AS ever_returned
FROM stays
WHERE cohort < 2026
GROUP BY cohort
ORDER BY cohort;


-- ---------------------------------------------------------------------
-- Q10. Superhosts vs other hosts (subquery per listing, then compare groups)
-- ---------------------------------------------------------------------
SELECT IF(h.is_superhost, 'superhost', 'regular') AS host_type,
       COUNT(*)                         AS listings,
       ROUND(AVG(x.stays), 1)           AS avg_stays_per_listing,
       ROUND(AVG(x.avg_rating), 2)      AS avg_rating,
       ROUND(AVG(h.response_rate), 1)   AS avg_response_rate,
       ROUND(100 * AVG(l.instant_bookable), 1) AS pct_instant_bookable
FROM listings l
JOIN hosts h ON h.host_id = l.host_id
JOIN (SELECT l2.listing_id,
             (SELECT COUNT(*) FROM bookings b WHERE b.listing_id = l2.listing_id AND b.status = 'completed') AS stays,
             (SELECT AVG(r.rating) FROM reviews r WHERE r.listing_id = l2.listing_id) AS avg_rating
      FROM listings l2) x ON x.listing_id = l.listing_id
GROUP BY host_type;


-- ---------------------------------------------------------------------
-- Q11. Which amenities go with better ratings? (many-to-many join, HAVING)
-- Avg rating of listings with each amenity vs the overall average. Correlation only.
-- ---------------------------------------------------------------------
WITH listing_rating AS (
  SELECT listing_id, AVG(rating) AS avg_rating
  FROM reviews WHERE rating IS NOT NULL
  GROUP BY listing_id
),
overall AS (SELECT AVG(avg_rating) AS avg_all FROM listing_rating)
SELECT a.amenity_name, a.category,
       COUNT(*)                                      AS listings_with_it,
       ROUND(AVG(lr.avg_rating), 3)                  AS avg_rating,
       ROUND(AVG(lr.avg_rating) - MAX(o.avg_all), 3) AS vs_overall
FROM listing_amenities la
JOIN amenities a       ON a.amenity_id = la.amenity_id
JOIN listing_rating lr ON lr.listing_id = la.listing_id
CROSS JOIN overall o
GROUP BY a.amenity_id, a.amenity_name, a.category
HAVING COUNT(*) >= 200
ORDER BY vs_overall DESC
LIMIT 15;


-- ---------------------------------------------------------------------
-- Q12. Gaps between stays: how long does a listing sit empty between bookings? (LEAD)
-- ---------------------------------------------------------------------
WITH seq AS (
  SELECT b.listing_id, n.city, b.check_out,
         LEAD(b.check_in) OVER (PARTITION BY b.listing_id ORDER BY b.check_in) AS next_check_in
  FROM bookings b
  JOIN listings l       ON l.listing_id = b.listing_id
  JOIN neighbourhoods n ON n.neighbourhood_id = l.neighbourhood_id
  WHERE b.status IN ('completed', 'confirmed', 'no_show')
)
SELECT city,
       COUNT(*)                                          AS gaps,
       ROUND(AVG(DATEDIFF(next_check_in, check_out)), 1) AS avg_gap_days,
       ROUND(100 * AVG(next_check_in = check_out), 1)    AS pct_back_to_back
FROM seq
WHERE next_check_in IS NOT NULL
GROUP BY city
ORDER BY avg_gap_days;


-- ---------------------------------------------------------------------
-- Q13. Pareto check: what share of revenue comes from the top 20% of listings?
-- (PERCENT_RANK + running share)
-- ---------------------------------------------------------------------
WITH lr AS (
  SELECT n.city, b.listing_id, SUM(b.total_price) AS revenue
  FROM bookings b
  JOIN listings l       ON l.listing_id = b.listing_id
  JOIN neighbourhoods n ON n.neighbourhood_id = l.neighbourhood_id
  WHERE b.status = 'completed'
  GROUP BY n.city, b.listing_id
),
ranked AS (
  SELECT city, revenue,
         PERCENT_RANK() OVER (PARTITION BY city ORDER BY revenue DESC) AS pr,
         SUM(revenue) OVER (PARTITION BY city)                         AS city_total
  FROM lr
)
SELECT city,
       ROUND(100 * SUM(CASE WHEN pr < 0.2 THEN revenue END) / MAX(city_total), 1) AS top20_pct_listings_share,
       ROUND(100 * SUM(CASE WHEN pr >= 0.8 THEN revenue END) / MAX(city_total), 1) AS bottom20_pct_listings_share
FROM ranked
GROUP BY city;


-- ---------------------------------------------------------------------
-- Q14. Money check: is every completed stay fully paid? (two aggregates joined)
-- Net paid = completed + pending - refunds. Lists bookings where it doesn't match the total.
-- ---------------------------------------------------------------------
WITH paid AS (
  SELECT booking_id,
         SUM(CASE WHEN payment_status IN ('completed', 'pending', 'refunded') THEN amount ELSE 0 END) AS net_paid,
         COUNT(*) AS payments
  FROM payments
  GROUP BY booking_id
)
SELECT b.status,
       COUNT(*)                                          AS bookings,
       SUM(p.booking_id IS NULL)                         AS no_payment_record,
       SUM(p.net_paid = b.total_price)                   AS paid_in_full,
       SUM(p.net_paid > 0 AND p.net_paid < b.total_price) AS partly_paid_or_refunded,
       SUM(p.net_paid <= 0)                              AS fully_refunded_or_unpaid
FROM bookings b
LEFT JOIN paid p ON p.booking_id = b.booking_id
GROUP BY b.status
ORDER BY bookings DESC;
