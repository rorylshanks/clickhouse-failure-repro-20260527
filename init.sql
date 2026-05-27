CREATE OR REPLACE FUNCTION sleepy_start()
RETURNS SETOF integer AS $$
BEGIN
    PERFORM pg_sleep(3600);
    RETURN NEXT 1;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE VIEW sleepy_view AS
SELECT sleepy_start() AS id;
