defmodule Bonfire.Social.TaggedOrFeedActivityIntegration do
  @moduledoc false
  import Ecto.Migration

  @pointer_table Needle.Pointer.__schema__(:source)
  @feed_publish_table Bonfire.Data.Social.FeedPublish.__schema__(:source)
  @hashtag_table_id Needle.ULID.as_uuid(Bonfire.Tag.Hashtag.__pointers__(:table_id))

  def up do
    execute("""
    CREATE OR REPLACE FUNCTION sync_feed_publish_with_tagged()
    RETURNS TRIGGER AS $$
    DECLARE
      is_hashtag boolean;
    BEGIN
      IF TG_OP = 'INSERT' THEN

        SELECT table_id = '#{@hashtag_table_id}' INTO is_hashtag FROM #{@pointer_table} WHERE id = NEW.tag_id;

        RAISE NOTICE 'tag_id: %, is_hashtag: %', NEW.tag_id, is_hashtag;

        IF is_hashtag THEN
          INSERT INTO #{@feed_publish_table} (id, feed_id)
          VALUES (NEW.id, NEW.tag_id)
          ON CONFLICT DO NOTHING;
        END IF;

        RETURN NEW;

      ELSIF TG_OP = 'DELETE' THEN

        DELETE FROM #{@feed_publish_table}
        WHERE id = OLD.id AND feed_id = OLD.tag_id;
        RETURN OLD;

      END IF;
      RETURN NULL;
    END;
    $$ LANGUAGE plpgsql;
    """)

    execute("""
    DROP TRIGGER IF EXISTS tagged_feed_publish_sync ON bonfire_tagged;
    """)

    execute("""
    CREATE TRIGGER tagged_feed_publish_sync
    AFTER INSERT OR DELETE ON bonfire_tagged
    FOR EACH ROW EXECUTE FUNCTION sync_feed_publish_with_tagged();
    """)
  end

  def down do
    execute("DROP TRIGGER IF EXISTS tagged_feed_publish_sync ON bonfire_tagged;")
    execute("DROP FUNCTION IF EXISTS sync_feed_publish_with_tagged();")
  end
end
