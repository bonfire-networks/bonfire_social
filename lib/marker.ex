defmodule Bonfire.Social.Marker do
  @moduledoc """
  Canonical per-account reading position for a feed, shared by the web UI and
  the Mastodon-compatible markers API.

  One small mutable row per `{account, feed_name}`, written with an atomic
  upsert (so high-frequency scroll saves never read-modify-write a larger
  structure, and concurrent tabs/clients can't clobber each other).

  Positions are last-write-wins: a marker is "where I am", not a high-water
  mark, so it must be able to move backward for cross-device resume to work
  (Mastodon behaves the same; its clients enforce monotonicity themselves).

  `account_id` holds the account's pointer id like `Seen` subjects do, falling
  back to the user id when no account is resolvable from the given subject.
  """

  use Ecto.Schema

  @primary_key false
  schema "bonfire_social_marker" do
    field :account_id, Needle.ULID, primary_key: true
    field :feed_name, :string, primary_key: true
    field :last_read_id, Needle.ULID
    field :version, :integer, default: 0
    timestamps(type: :utc_datetime_usec)
  end
end

defmodule Bonfire.Social.Marker.Migration do
  @moduledoc false
  use Ecto.Migration
  import Needle.Migration

  def create_marker_table do
    create_if_not_exists table(:bonfire_social_marker, primary_key: false) do
      add :account_id, strong_pointer(), primary_key: true
      add :feed_name, :text, primary_key: true
      add :last_read_id, :uuid, null: false
      add :version, :bigint, null: false, default: 0
      timestamps(type: :utc_datetime_usec)
    end
  end

  def drop_marker_table do
    drop_if_exists table(:bonfire_social_marker)
  end

  def migrate_marker do
    case direction() do
      :up -> create_marker_table()
      :down -> drop_marker_table()
    end
  end
end
