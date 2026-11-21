-- =====================================================================
-- 01_raw_schema_and_load.sql  -  raw database (airbnb_raw) + CSV load
-- =====================================================================
-- Everything is VARCHAR/TEXT so the dirty values load exactly as they are.
-- Typing and cleaning happen later in 02/03. Needs local_infile = 1 (see 00).

CREATE DATABASE IF NOT EXISTS airbnb_raw CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci;
USE airbnb_raw;

DROP TABLE IF EXISTS raw_neighbourhoods;
CREATE TABLE raw_neighbourhoods (
  raw_row_id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  `neighbourhood_id` VARCHAR(255) NULL,
  `neighbourhood_name` VARCHAR(255) NULL,
  `city` VARCHAR(255) NULL,
  `country` VARCHAR(255) NULL,
  `latitude` VARCHAR(255) NULL,
  `longitude` VARCHAR(255) NULL,
  source_file VARCHAR(100) NOT NULL,
  loaded_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (raw_row_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

DROP TABLE IF EXISTS raw_hosts;
CREATE TABLE raw_hosts (
  raw_row_id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  `host_id` VARCHAR(255) NULL,
  `first_name` VARCHAR(255) NULL,
  `last_name` VARCHAR(255) NULL,
  `email` VARCHAR(255) NULL,
  `phone` VARCHAR(255) NULL,
  `country` VARCHAR(255) NULL,
  `host_since` VARCHAR(255) NULL,
  `is_superhost` VARCHAR(255) NULL,
  `response_rate` VARCHAR(255) NULL,
  `identity_verified` VARCHAR(255) NULL,
  `updated_at` VARCHAR(255) NULL,
  source_file VARCHAR(100) NOT NULL,
  loaded_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (raw_row_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

DROP TABLE IF EXISTS raw_guests;
CREATE TABLE raw_guests (
  raw_row_id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  `guest_id` VARCHAR(255) NULL,
  `first_name` VARCHAR(255) NULL,
  `last_name` VARCHAR(255) NULL,
  `email` VARCHAR(255) NULL,
  `phone` VARCHAR(255) NULL,
  `gender` VARCHAR(255) NULL,
  `date_of_birth` VARCHAR(255) NULL,
  `country` VARCHAR(255) NULL,
  `signup_date` VARCHAR(255) NULL,
  source_file VARCHAR(100) NOT NULL,
  loaded_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (raw_row_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

DROP TABLE IF EXISTS raw_listings;
CREATE TABLE raw_listings (
  raw_row_id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  `listing_id` VARCHAR(255) NULL,
  `host_id` VARCHAR(255) NULL,
  `neighbourhood_id` VARCHAR(255) NULL,
  `title` VARCHAR(255) NULL,
  `property_type` VARCHAR(255) NULL,
  `room_type` VARCHAR(255) NULL,
  `accommodates` VARCHAR(255) NULL,
  `bedrooms` VARCHAR(255) NULL,
  `bathrooms` VARCHAR(255) NULL,
  `price` VARCHAR(255) NULL,
  `currency` VARCHAR(255) NULL,
  `cleaning_fee` VARCHAR(255) NULL,
  `minimum_nights` VARCHAR(255) NULL,
  `maximum_nights` VARCHAR(255) NULL,
  `latitude` VARCHAR(255) NULL,
  `longitude` VARCHAR(255) NULL,
  `instant_bookable` VARCHAR(255) NULL,
  `status` VARCHAR(255) NULL,
  `created_at` VARCHAR(255) NULL,
  `updated_at` VARCHAR(255) NULL,
  source_file VARCHAR(100) NOT NULL,
  loaded_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (raw_row_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

DROP TABLE IF EXISTS raw_amenities;
CREATE TABLE raw_amenities (
  raw_row_id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  `amenity_id` VARCHAR(255) NULL,
  `amenity_name` VARCHAR(255) NULL,
  `category` VARCHAR(255) NULL,
  source_file VARCHAR(100) NOT NULL,
  loaded_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (raw_row_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

DROP TABLE IF EXISTS raw_listing_amenities;
CREATE TABLE raw_listing_amenities (
  raw_row_id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  `listing_id` VARCHAR(255) NULL,
  `amenity_id` VARCHAR(255) NULL,
  source_file VARCHAR(100) NOT NULL,
  loaded_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (raw_row_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

DROP TABLE IF EXISTS raw_bookings;
CREATE TABLE raw_bookings (
  raw_row_id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  `booking_id` VARCHAR(255) NULL,
  `listing_id` VARCHAR(255) NULL,
  `guest_id` VARCHAR(255) NULL,
  `booking_date` VARCHAR(255) NULL,
  `check_in` VARCHAR(255) NULL,
  `check_out` VARCHAR(255) NULL,
  `num_guests` VARCHAR(255) NULL,
  `nightly_rate` VARCHAR(255) NULL,
  `cleaning_fee` VARCHAR(255) NULL,
  `total_price` VARCHAR(255) NULL,
  `currency` VARCHAR(255) NULL,
  `status` VARCHAR(255) NULL,
  `channel` VARCHAR(255) NULL,
  source_file VARCHAR(100) NOT NULL,
  loaded_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (raw_row_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

DROP TABLE IF EXISTS raw_payments;
CREATE TABLE raw_payments (
  raw_row_id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  `payment_id` VARCHAR(255) NULL,
  `booking_id` VARCHAR(255) NULL,
  `payment_date` VARCHAR(255) NULL,
  `amount` VARCHAR(255) NULL,
  `currency` VARCHAR(255) NULL,
  `payment_method` VARCHAR(255) NULL,
  `payment_status` VARCHAR(255) NULL,
  `transaction_ref` VARCHAR(255) NULL,
  source_file VARCHAR(100) NOT NULL,
  loaded_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (raw_row_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

DROP TABLE IF EXISTS raw_reviews;
CREATE TABLE raw_reviews (
  raw_row_id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  `review_id` VARCHAR(255) NULL,
  `booking_id` VARCHAR(255) NULL,
  `listing_id` VARCHAR(255) NULL,
  `guest_id` VARCHAR(255) NULL,
  `review_date` VARCHAR(255) NULL,
  `rating` VARCHAR(255) NULL,
  `cleanliness` VARCHAR(255) NULL,
  `communication` VARCHAR(255) NULL,
  `value` VARCHAR(255) NULL,
  `comments` TEXT NULL,
  source_file VARCHAR(100) NOT NULL,
  loaded_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (raw_row_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- Load the CSVs from my project folder
LOAD DATA LOCAL INFILE 'C:/Users/algir/Desktop/Projects/SQL/MySQL/Airbnb/neighbourhoods.csv'
INTO TABLE raw_neighbourhoods
CHARACTER SET utf8mb4
FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '"' ESCAPED BY ''
LINES TERMINATED BY '\n'
IGNORE 1 LINES
(`neighbourhood_id`, `neighbourhood_name`, `city`, `country`, `latitude`, `longitude`)
SET source_file = 'neighbourhoods.csv';

LOAD DATA LOCAL INFILE 'C:/Users/algir/Desktop/Projects/SQL/MySQL/Airbnb/hosts.csv'
INTO TABLE raw_hosts
CHARACTER SET utf8mb4
FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '"' ESCAPED BY ''
LINES TERMINATED BY '\n'
IGNORE 1 LINES
(`host_id`, `first_name`, `last_name`, `email`, `phone`, `country`, `host_since`, `is_superhost`, `response_rate`, `identity_verified`, `updated_at`)
SET source_file = 'hosts.csv';

LOAD DATA LOCAL INFILE 'C:/Users/algir/Desktop/Projects/SQL/MySQL/Airbnb/guests.csv'
INTO TABLE raw_guests
CHARACTER SET utf8mb4
FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '"' ESCAPED BY ''
LINES TERMINATED BY '\n'
IGNORE 1 LINES
(`guest_id`, `first_name`, `last_name`, `email`, `phone`, `gender`, `date_of_birth`, `country`, `signup_date`)
SET source_file = 'guests.csv';

LOAD DATA LOCAL INFILE 'C:/Users/algir/Desktop/Projects/SQL/MySQL/Airbnb/listings.csv'
INTO TABLE raw_listings
CHARACTER SET utf8mb4
FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '"' ESCAPED BY ''
LINES TERMINATED BY '\n'
IGNORE 1 LINES
(`listing_id`, `host_id`, `neighbourhood_id`, `title`, `property_type`, `room_type`, `accommodates`, `bedrooms`, `bathrooms`, `price`, `currency`, `cleaning_fee`, `minimum_nights`, `maximum_nights`, `latitude`, `longitude`, `instant_bookable`, `status`, `created_at`, `updated_at`)
SET source_file = 'listings.csv';

LOAD DATA LOCAL INFILE 'C:/Users/algir/Desktop/Projects/SQL/MySQL/Airbnb/amenities.csv'
INTO TABLE raw_amenities
CHARACTER SET utf8mb4
FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '"' ESCAPED BY ''
LINES TERMINATED BY '\n'
IGNORE 1 LINES
(`amenity_id`, `amenity_name`, `category`)
SET source_file = 'amenities.csv';

LOAD DATA LOCAL INFILE 'C:/Users/algir/Desktop/Projects/SQL/MySQL/Airbnb/listing_amenities.csv'
INTO TABLE raw_listing_amenities
CHARACTER SET utf8mb4
FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '"' ESCAPED BY ''
LINES TERMINATED BY '\n'
IGNORE 1 LINES
(`listing_id`, `amenity_id`)
SET source_file = 'listing_amenities.csv';

LOAD DATA LOCAL INFILE 'C:/Users/algir/Desktop/Projects/SQL/MySQL/Airbnb/bookings.csv'
INTO TABLE raw_bookings
CHARACTER SET utf8mb4
FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '"' ESCAPED BY ''
LINES TERMINATED BY '\n'
IGNORE 1 LINES
(`booking_id`, `listing_id`, `guest_id`, `booking_date`, `check_in`, `check_out`, `num_guests`, `nightly_rate`, `cleaning_fee`, `total_price`, `currency`, `status`, `channel`)
SET source_file = 'bookings.csv';

LOAD DATA LOCAL INFILE 'C:/Users/algir/Desktop/Projects/SQL/MySQL/Airbnb/payments.csv'
INTO TABLE raw_payments
CHARACTER SET utf8mb4
FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '"' ESCAPED BY ''
LINES TERMINATED BY '\n'
IGNORE 1 LINES
(`payment_id`, `booking_id`, `payment_date`, `amount`, `currency`, `payment_method`, `payment_status`, `transaction_ref`)
SET source_file = 'payments.csv';

LOAD DATA LOCAL INFILE 'C:/Users/algir/Desktop/Projects/SQL/MySQL/Airbnb/reviews.csv'
INTO TABLE raw_reviews
CHARACTER SET utf8mb4
FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '"' ESCAPED BY ''
LINES TERMINATED BY '\n'
IGNORE 1 LINES
(`review_id`, `booking_id`, `listing_id`, `guest_id`, `review_date`, `rating`, `cleanliness`, `communication`, `value`, `comments`)
SET source_file = 'reviews.csv';

-- Row counts, should match the README
SELECT 'raw_neighbourhoods' AS tbl, COUNT(*) AS n FROM raw_neighbourhoods
UNION ALL
SELECT 'raw_hosts' AS tbl, COUNT(*) AS n FROM raw_hosts
UNION ALL
SELECT 'raw_guests' AS tbl, COUNT(*) AS n FROM raw_guests
UNION ALL
SELECT 'raw_listings' AS tbl, COUNT(*) AS n FROM raw_listings
UNION ALL
SELECT 'raw_amenities' AS tbl, COUNT(*) AS n FROM raw_amenities
UNION ALL
SELECT 'raw_listing_amenities' AS tbl, COUNT(*) AS n FROM raw_listing_amenities
UNION ALL
SELECT 'raw_bookings' AS tbl, COUNT(*) AS n FROM raw_bookings
UNION ALL
SELECT 'raw_payments' AS tbl, COUNT(*) AS n FROM raw_payments
UNION ALL
SELECT 'raw_reviews' AS tbl, COUNT(*) AS n FROM raw_reviews;


