ALTER TABLE telemetry_samples
    ADD COLUMN watch_build_id text CHECK (
        watch_build_id IS NULL OR (
            length(watch_build_id) BETWEEN 1 AND 32
            AND watch_build_id ~ '^[A-Za-z0-9._+-]+$'
        )
    ),
    ADD COLUMN transport_timeout_count integer CHECK (
        transport_timeout_count IS NULL OR transport_timeout_count BETWEEN 0 AND 2147483647
    ),
    ADD COLUMN transport_error_count integer CHECK (
        transport_error_count IS NULL OR transport_error_count BETWEEN 0 AND 2147483647
    ),
    ADD COLUMN transport_exception_count integer CHECK (
        transport_exception_count IS NULL OR transport_exception_count BETWEEN 0 AND 2147483647
    ),
    ADD COLUMN transport_consecutive_failures integer CHECK (
        transport_consecutive_failures IS NULL OR transport_consecutive_failures BETWEEN 0 AND 2147483647
    ),
    ADD COLUMN transport_last_outcome smallint CHECK (
        transport_last_outcome IS NULL OR transport_last_outcome BETWEEN 0 AND 4
    );
