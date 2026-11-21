-- =====================================================================
-- 02_clean_schema.sql  -  clean database (airbnb_clean)
-- =====================================================================
-- Typed tables with PKs, FKs and CHECK constraints. Drops and rebuilds
-- airbnb_clean (raw is not touched). Run before 03.


DROP DATABASE IF EXISTS airbnb_clean;
CREATE DATABASE airbnb_clean CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci;
USE airbnb_clean;

-- ---------------------------------------------------------------------
-- Lookup tables
-- ---------------------------------------------------------------------

CREATE TABLE countries (
  country_name        VARCHAR(60)  NOT NULL,
  iso2                CHAR(2)      NOT NULL,
  calling_code        VARCHAR(4)   NOT NULL,
  phone_national_len  TINYINT UNSIGNED NOT NULL,
  PRIMARY KEY (country_name),
  UNIQUE KEY uq_countries_iso2 (iso2)
) ENGINE=InnoDB;

INSERT INTO countries (country_name, iso2, calling_code, phone_national_len) VALUES
  ('United Kingdom', 'GB', '44', 10),
  ('France',         'FR', '33', 9),
  ('Spain',          'ES', '34', 9),
  ('Netherlands',    'NL', '31', 9),
  ('Germany',        'DE', '49', 11),
  ('United States',  'US', '1',  10),
  ('Italy',          'IT', '39', 10),
  ('Ireland',        'IE', '353', 9),
  ('Poland',         'PL', '48', 9),
  ('Portugal',       'PT', '351', 9),
  ('Canada',         'CA', '1',  10),
  ('Australia',      'AU', '61', 9),
  ('Sweden',         'SE', '46', 9);

CREATE TABLE cities (
  city          VARCHAR(40) NOT NULL,
  country_name  VARCHAR(60) NOT NULL,
  currency      CHAR(3)     NOT NULL,
  PRIMARY KEY (city),
  CONSTRAINT fk_cities_country FOREIGN KEY (country_name) REFERENCES countries (country_name),
  CONSTRAINT chk_cities_currency CHECK (currency IN ('GBP', 'EUR'))
) ENGINE=InnoDB;

INSERT INTO cities (city, country_name, currency) VALUES
  ('London',    'United Kingdom', 'GBP'),
  ('Paris',     'France',         'EUR'),
  ('Barcelona', 'Spain',          'EUR'),
  ('Amsterdam', 'Netherlands',    'EUR');

-- ---------------------------------------------------------------------
-- Core tables (parents first so the FKs resolve)
-- ---------------------------------------------------------------------

CREATE TABLE neighbourhoods (
  neighbourhood_id    INT UNSIGNED  NOT NULL,
  neighbourhood_name  VARCHAR(100)  NOT NULL,
  city                VARCHAR(40)   NOT NULL,
  latitude            DECIMAL(9,6)  NOT NULL,
  longitude           DECIMAL(9,6)  NOT NULL,
  PRIMARY KEY (neighbourhood_id),
  UNIQUE KEY uq_neighbourhoods_city_name (city, neighbourhood_name),
  CONSTRAINT fk_neighbourhoods_city FOREIGN KEY (city) REFERENCES cities (city),
  CONSTRAINT chk_neighbourhoods_lat CHECK (latitude BETWEEN -90 AND 90),
  CONSTRAINT chk_neighbourhoods_lon CHECK (longitude BETWEEN -180 AND 180)
) ENGINE=InnoDB;

CREATE TABLE hosts (
  host_id            INT UNSIGNED  NOT NULL,
  first_name         VARCHAR(100)  NOT NULL,
  last_name          VARCHAR(100)  NULL,
  email              VARCHAR(254)  NULL,
  phone              VARCHAR(16)   NULL,
  country            VARCHAR(60)   NULL,
  host_since         DATE          NULL,
  is_superhost       BOOLEAN       NOT NULL,
  response_rate      TINYINT UNSIGNED NULL,
  identity_verified  BOOLEAN       NOT NULL,
  updated_at         DATETIME      NULL,
  PRIMARY KEY (host_id),

  KEY ix_hosts_email (email),
  CONSTRAINT fk_hosts_country FOREIGN KEY (country) REFERENCES countries (country_name),
  CONSTRAINT chk_hosts_email CHECK (email = LOWER(email) AND email LIKE '_%@_%._%'),
  CONSTRAINT chk_hosts_phone CHECK (REGEXP_LIKE(phone, '^[+][1-9][0-9]{6,14}$')),
  CONSTRAINT chk_hosts_response_rate CHECK (response_rate <= 100)
) ENGINE=InnoDB;

CREATE TABLE guests (
  guest_id       INT UNSIGNED  NOT NULL,
  first_name     VARCHAR(100)  NOT NULL,
  last_name      VARCHAR(100)  NULL,
  email          VARCHAR(254)  NULL,
  phone          VARCHAR(16)   NULL,
  gender         VARCHAR(12)   NULL,
  date_of_birth  DATE          NULL,
  country        VARCHAR(60)   NULL,
  signup_date    DATE          NULL,
  PRIMARY KEY (guest_id),
  KEY ix_guests_email (email),
  CONSTRAINT fk_guests_country FOREIGN KEY (country) REFERENCES countries (country_name),
  CONSTRAINT chk_guests_email CHECK (email = LOWER(email) AND email LIKE '_%@_%._%'),
  CONSTRAINT chk_guests_phone CHECK (REGEXP_LIKE(phone, '^[+][1-9][0-9]{6,14}$')),
  CONSTRAINT chk_guests_gender CHECK (gender IN ('female', 'male', 'non_binary', 'undisclosed'))
) ENGINE=InnoDB;

CREATE TABLE amenities (
  amenity_id    SMALLINT UNSIGNED NOT NULL,
  amenity_name  VARCHAR(100) NOT NULL,
  category      VARCHAR(30)  NULL,
  PRIMARY KEY (amenity_id),
  UNIQUE KEY uq_amenities_name (amenity_name)
) ENGINE=InnoDB;

CREATE TABLE listings (
  listing_id        INT UNSIGNED  NOT NULL,
  host_id           INT UNSIGNED  NOT NULL,
  neighbourhood_id  INT UNSIGNED  NOT NULL,
  title             VARCHAR(255)  NOT NULL,
  property_type     VARCHAR(20)   NOT NULL,
  room_type         VARCHAR(20)   NOT NULL,
  accommodates      TINYINT UNSIGNED NULL,
  bedrooms          TINYINT UNSIGNED NULL,
  bathrooms         DECIMAL(3,1)  NULL,
  price             DECIMAL(10,2) NULL,
  currency          CHAR(3)       NOT NULL,
  cleaning_fee      DECIMAL(10,2) NULL,
  minimum_nights    SMALLINT UNSIGNED NULL,
  maximum_nights    SMALLINT UNSIGNED NULL,
  latitude          DECIMAL(9,6)  NULL,
  longitude         DECIMAL(9,6)  NULL,
  coords_imputed    BOOLEAN       NOT NULL DEFAULT 0,
  instant_bookable  BOOLEAN       NOT NULL,
  status            VARCHAR(10)   NOT NULL,
  created_at        DATE          NULL,
  updated_at        DATETIME      NULL,
  PRIMARY KEY (listing_id),
  KEY ix_listings_host (host_id),
  KEY ix_listings_neighbourhood (neighbourhood_id),
  CONSTRAINT fk_listings_host FOREIGN KEY (host_id) REFERENCES hosts (host_id),
  CONSTRAINT fk_listings_neighbourhood FOREIGN KEY (neighbourhood_id) REFERENCES neighbourhoods (neighbourhood_id),
  CONSTRAINT chk_listings_property_type CHECK (property_type IN
    ('apartment', 'house', 'condo', 'loft', 'townhouse', 'studio', 'guest_suite', 'villa', 'boat')),
  CONSTRAINT chk_listings_room_type CHECK (room_type IN ('entire_home', 'private_room', 'shared_room', 'hotel_room')),
  CONSTRAINT chk_listings_status CHECK (status IN ('active', 'inactive', 'delisted')),
  CONSTRAINT chk_listings_currency CHECK (currency IN ('GBP', 'EUR')),
  CONSTRAINT chk_listings_accommodates CHECK (accommodates BETWEEN 1 AND 30),
  CONSTRAINT chk_listings_price CHECK (price > 0),
  CONSTRAINT chk_listings_cleaning_fee CHECK (cleaning_fee >= 0),
  CONSTRAINT chk_listings_nights CHECK (minimum_nights >= 1 AND minimum_nights <= maximum_nights),
  CONSTRAINT chk_listings_lat CHECK (latitude BETWEEN -90 AND 90),
  CONSTRAINT chk_listings_lon CHECK (longitude BETWEEN -180 AND 180)
) ENGINE=InnoDB;

-- listing <-> amenity (many-to-many)
CREATE TABLE listing_amenities (
  listing_id  INT UNSIGNED      NOT NULL,
  amenity_id  SMALLINT UNSIGNED NOT NULL,
  PRIMARY KEY (listing_id, amenity_id),
  KEY ix_listing_amenities_amenity (amenity_id),
  CONSTRAINT fk_la_listing FOREIGN KEY (listing_id) REFERENCES listings (listing_id),
  CONSTRAINT fk_la_amenity FOREIGN KEY (amenity_id) REFERENCES amenities (amenity_id)
) ENGINE=InnoDB;

CREATE TABLE bookings (
  booking_id    INT UNSIGNED  NOT NULL,
  listing_id    INT UNSIGNED  NOT NULL,
  guest_id      INT UNSIGNED  NOT NULL,
  booking_date  DATETIME      NULL,
  check_in      DATE          NOT NULL,
  check_out     DATE          NOT NULL,

  nights        SMALLINT GENERATED ALWAYS AS (DATEDIFF(check_out, check_in)) STORED,
  num_guests    TINYINT UNSIGNED NULL,
  nightly_rate  DECIMAL(10,2) NOT NULL,
  cleaning_fee  DECIMAL(10,2) NOT NULL DEFAULT 0,
  total_price   DECIMAL(12,2) NOT NULL,
  currency      CHAR(3)       NOT NULL,
  status        VARCHAR(10)   NULL,
  channel       VARCHAR(12)   NOT NULL,
  PRIMARY KEY (booking_id),
  -- needed for the composite FK from reviews
  UNIQUE KEY uq_bookings_booking_listing_guest (booking_id, listing_id, guest_id),
  KEY ix_bookings_listing_dates (listing_id, check_in),
  KEY ix_bookings_guest (guest_id),
  CONSTRAINT fk_bookings_listing FOREIGN KEY (listing_id) REFERENCES listings (listing_id),
  CONSTRAINT fk_bookings_guest FOREIGN KEY (guest_id) REFERENCES guests (guest_id),
  CONSTRAINT chk_bookings_dates CHECK (check_out > check_in),
  CONSTRAINT chk_bookings_num_guests CHECK (num_guests >= 1),
  CONSTRAINT chk_bookings_rate CHECK (nightly_rate > 0),
  CONSTRAINT chk_bookings_fee CHECK (cleaning_fee >= 0),
  -- total = nights * nightly_rate + cleaning_fee
  CONSTRAINT chk_bookings_total CHECK (total_price = nights * nightly_rate + cleaning_fee),
  CONSTRAINT chk_bookings_currency CHECK (currency IN ('GBP', 'EUR')),
  CONSTRAINT chk_bookings_status CHECK (status IN ('completed', 'cancelled', 'confirmed', 'no_show')),
  CONSTRAINT chk_bookings_channel CHECK (channel IN ('web', 'ios', 'android', 'partner_api'))
) ENGINE=InnoDB;



CREATE TABLE payments (
  payment_id       INT UNSIGNED  NOT NULL,
  booking_id       INT UNSIGNED  NOT NULL,
  payment_date     DATETIME      NOT NULL,
  amount           DECIMAL(12,2) NOT NULL,
  currency         CHAR(3)       NOT NULL,
  payment_method   VARCHAR(15)   NULL,
  payment_status   VARCHAR(10)   NOT NULL,
  transaction_ref  CHAR(14)      NOT NULL,
  PRIMARY KEY (payment_id),
  UNIQUE KEY uq_payments_transaction_ref (transaction_ref),
  KEY ix_payments_booking (booking_id),
  CONSTRAINT fk_payments_booking FOREIGN KEY (booking_id) REFERENCES bookings (booking_id),
  CONSTRAINT chk_payments_currency CHECK (currency IN ('GBP', 'EUR')),
  CONSTRAINT chk_payments_method CHECK (payment_method IN
    ('credit_card', 'debit_card', 'paypal', 'apple_pay', 'google_pay', 'bank_transfer')),
  CONSTRAINT chk_payments_status CHECK (payment_status IN ('completed', 'refunded', 'failed', 'pending')),
  CONSTRAINT chk_payments_refund_sign CHECK ((payment_status = 'refunded' AND amount < 0)
                                          OR (payment_status <> 'refunded' AND amount > 0)),
  CONSTRAINT chk_payments_ref CHECK (REGEXP_LIKE(transaction_ref, '^TXN-[0-9A-F]{10}$', 'c'))
) ENGINE=InnoDB;

CREATE TABLE reviews (
  review_id      INT UNSIGNED  NOT NULL,
  booking_id     INT UNSIGNED  NOT NULL,
  listing_id     INT UNSIGNED  NOT NULL,
  guest_id       INT UNSIGNED  NOT NULL,
  review_date    DATE          NULL,
  rating         TINYINT UNSIGNED NULL,
  cleanliness    TINYINT UNSIGNED NULL,
  communication  TINYINT UNSIGNED NULL,
  value          TINYINT UNSIGNED NULL,
  comments       TEXT          NULL,
  PRIMARY KEY (review_id),
  UNIQUE KEY uq_reviews_booking (booking_id),
  KEY ix_reviews_listing (listing_id),
  KEY ix_reviews_guest (guest_id),
  -- review must match the booking's guest and listing
  CONSTRAINT fk_reviews_booking FOREIGN KEY (booking_id, listing_id, guest_id)
    REFERENCES bookings (booking_id, listing_id, guest_id),
  CONSTRAINT fk_reviews_listing FOREIGN KEY (listing_id) REFERENCES listings (listing_id),
  CONSTRAINT fk_reviews_guest FOREIGN KEY (guest_id) REFERENCES guests (guest_id),
  CONSTRAINT chk_reviews_rating CHECK (rating BETWEEN 1 AND 5),
  CONSTRAINT chk_reviews_cleanliness CHECK (cleanliness BETWEEN 1 AND 5),
  CONSTRAINT chk_reviews_communication CHECK (communication BETWEEN 1 AND 5),
  CONSTRAINT chk_reviews_value CHECK (value BETWEEN 1 AND 5)
) ENGINE=InnoDB;

-- Check what got created
SELECT table_name, table_rows
FROM information_schema.tables
WHERE table_schema = 'airbnb_clean'
ORDER BY table_name;
