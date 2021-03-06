WITH
  base AS (
  SELECT
    * REPLACE (
      CASE app_name
        WHEN 'Fennec' THEN CONCAT(app_name, ' ', os)
        WHEN 'Focus' THEN CONCAT(app_name, ' ', os)
        WHEN 'Lockbox' THEN CONCAT('Lockwise ', os)
        WHEN 'Zerda' THEN 'Firefox Lite'
        ELSE app_name
      END AS app_name),
    normalized_channel AS channel,
    (campaign IS NOT NULL) AS attributed,
  FROM
    telemetry.nondesktop_clients_last_seen_v1
  WHERE
    -- We apply this filter here rather than in the live view because this field
    -- is not normalized and there are many single pings that come in with unique
    -- nonsensical app_name values. App names are documented in
    -- https://docs.telemetry.mozilla.org/concepts/choosing_a_dataset_mobile.html#products-overview
    (STARTS_WITH(app_name, 'FirefoxReality') OR
     ENDS_WITH(app_name, 'Baseline') OR
     app_name IN (
      'Fenix',
      'Fennec', -- Firefox for Android and Firefox for iOS
      'Focus',
      'Lockbox', -- Lockwise
      'FirefoxConnect', -- Amazon Echo
      'FirefoxForFireTV',
      'Firefox Preview',
      'Zerda')) -- Firefox Lite, previously called Rocket
    -- There are also many strange nonsensical entries for os, so we filter here.
    AND os IN ('Android', 'iOS')),
  --
  nested AS (
  SELECT
    submission_date,
    [
    STRUCT('Any Firefox Non-desktop Activity' AS usage,
      udf.smoot_usage_from_28_bits(ARRAY_AGG(STRUCT(days_created_profile_bits,
        days_seen_bits))) AS metrics)
    ] AS metrics_array,
    MOD(ABS(FARM_FINGERPRINT(client_id)), 20) AS id_bucket,
    app_name,
    app_version,
    country,
    locale,
    os,
    os_version,
    channel,
    attributed
  FROM
    base
  WHERE
    client_id IS NOT NULL
    -- Reprocess all dates by running this query with --parameter=submission_date:DATE:NULL
    AND (@submission_date IS NULL OR @submission_date = submission_date)
  GROUP BY
    submission_date,
    id_bucket,
    app_name,
    app_version,
    country,
    locale,
    os,
    os_version,
    channel,
    attributed ),
  --
  unnested AS (
  SELECT
    submission_date,
    m.usage,
    (SELECT AS STRUCT m.metrics.* EXCEPT (is_empty_group)) AS metrics,
    nested.* EXCEPT (submission_date, metrics_array)
  FROM
    nested
  CROSS JOIN
    UNNEST(metrics_array) AS m
  WHERE
    -- Optimization so we don't have to store rows where counts are all zero.
    NOT m.metrics.is_empty_group )
  --
SELECT
  *
FROM
  unnested
WHERE
  -- For the 'Firefox Non-desktop' umbrella, we include only apps that
  -- are considered for KPIs, so we filter out FireTV and Reality.
  app_name != 'FirefoxForFireTV'
  AND NOT ENDS_WITH(app_name, 'Baseline')
  AND NOT STARTS_WITH(app_name, 'FirefoxReality')
UNION ALL
SELECT
  -- Also present each app as its own usage criterion. App names are documented in
  -- https://docs.telemetry.mozilla.org/concepts/choosing_a_dataset_mobile.html#products-overview
  * REPLACE(REPLACE(usage, 'Firefox Non-desktop', app_name) AS usage)
FROM
  unnested
UNION ALL
SELECT
  -- We also present a single usage criterion that sums together Fenix + Firefox Preview
  -- as that represents total logic "Fenix" usage.
  * REPLACE(REPLACE(usage, 'Firefox Non-desktop', 'Preview+Fenix') AS usage)
FROM
  unnested
WHERE
  app_name IN ('Firefox Preview', 'Fenix')
