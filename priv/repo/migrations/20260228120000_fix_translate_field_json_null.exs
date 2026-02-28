defmodule Bonfire.Common.Repo.Migrations.FixTranslateFieldJsonNull do
  @moduledoc "Fix translate_field to use jsonb instead of json, so JSON null values are correctly treated as SQL NULL"
  use Ecto.Migration

  def up do
    execute("""
    CREATE OR REPLACE FUNCTION public.translate_field(record record, container varchar, field varchar, default_locale varchar, locales varchar[])
    RETURNS varchar
    STRICT
    STABLE
    LANGUAGE plpgsql
    AS $$
      DECLARE
        locale varchar;
        j jsonb;
        c jsonb;
      BEGIN
        j := to_jsonb(record);
        c := j->container;

        FOREACH locale IN ARRAY locales LOOP
          IF locale = default_locale THEN
            RETURN j->>field;
          ELSEIF c->locale IS NOT NULL THEN
            IF c->locale->>field IS NOT NULL THEN
              RETURN c->locale->>field;
            END IF;
          END IF;
        END LOOP;
        RETURN j->>field;
      END;
    $$;
    """)

    execute("""
    CREATE OR REPLACE FUNCTION public.translate_field(record record, container varchar, default_locale varchar, locales varchar[])
    RETURNS jsonb
    STRICT
    STABLE
    LANGUAGE plpgsql
    AS $$
      DECLARE
        locale varchar;
        j jsonb;
        c jsonb;
      BEGIN
        j := to_jsonb(record);
        c := j->container;

        FOREACH locale IN ARRAY locales LOOP
          IF c->locale IS NOT NULL THEN
            RETURN c->locale;
          END IF;
        END LOOP;
        RETURN NULL;
      END;
    $$;
    """)
  end

  def down do
    execute("""
    CREATE OR REPLACE FUNCTION public.translate_field(record record, container varchar, field varchar, default_locale varchar, locales varchar[])
    RETURNS varchar
    STRICT
    STABLE
    LANGUAGE plpgsql
    AS $$
      DECLARE
        locale varchar;
        j json;
        c json;
        l varchar;
      BEGIN
        j := row_to_json(record);
        c := j->container;

        FOREACH locale IN ARRAY locales LOOP
          IF locale = default_locale THEN
            RETURN j->>field;
          ELSEIF c->locale IS NOT NULL THEN
            IF c->locale->>field IS NOT NULL THEN
              RETURN c->locale->>field;
            END IF;
          END IF;
        END LOOP;
        RETURN j->>field;
      END;
    $$;
    """)

    execute("""
    CREATE OR REPLACE FUNCTION public.translate_field(record record, container varchar, default_locale varchar, locales varchar[])
    RETURNS jsonb
    STRICT
    STABLE
    LANGUAGE plpgsql
    AS $$
      DECLARE
        locale varchar;
        j json;
        c json;
      BEGIN
        j := row_to_json(record);
        c := j->container;

        FOREACH locale IN ARRAY locales LOOP
          IF c->locale IS NOT NULL THEN
            RETURN c->locale;
          END IF;
        END LOOP;
        RETURN NULL;
      END;
    $$;
    """)
  end
end
